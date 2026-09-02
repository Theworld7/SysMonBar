//
// SysMonBarApp.swift
//  SysMonBar — 单文件版菜单栏系统监控
//  macOS 13+ · Swift 5.9+ / Swift 6 兼容
//

import SwiftUI
import Combine
import AppKit
import Darwin
import SQLite3
import os.log

private let log = OSLog(subsystem: "com.theworld7.sysmonbar", category: "tick")

// MARK: - 数据模型

struct SystemSnapshot {
    var cpuUsage: Double = 0     // 0.0 ~ 1.0
    var memUsedGB: Double = 0
    var memTotalGB: Double = 0
    var diskUsedGB: Double = 0
    var diskTotalGB: Double = 0
    var netInKBps: Double = 0
    var netOutKBps: Double = 0

    var memPct: Double { memTotalGB > 0 ? memUsedGB / memTotalGB : 0 }
    var diskPct: Double { diskTotalGB > 0 ? diskUsedGB / diskTotalGB : 0 }
}

// MARK: - 采样器接口

protocol MetricReading {
    @discardableResult
    func read(into snap: inout SystemSnapshot) -> Bool
}

// MARK: - CPU 采样
//
// macOS 26 上 cpu_ticks 实际布局 [user, system, idle, ~0] 与文档不符
// （文档说 [user, nice, system, idle]），只取前三项。

final class CPUSampler: MetricReading {
    private struct Snapshot {
        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
    }

    private var last: Snapshot?
    private var hasBaseline = false

    /// 返回 0.0~1.0 的 CPU 使用率（两次采样间的差值）
    private func usage() -> Double {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &cpuLoad) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let t = cpuLoad.cpu_ticks
        let cur = Snapshot(
            user:   UInt64(t.0),
            system: UInt64(t.1),
            idle:   UInt64(t.2)
        )

        // 第一次只采基线
        guard let prev = last, hasBaseline else {
            last = cur
            hasBaseline = true
            return 0
        }
        last = cur

        let dUser   = cur.user   &- prev.user
        let dSystem = cur.system &- prev.system
        let dIdle   = cur.idle   &- prev.idle
        let total = dUser &+ dSystem &+ dIdle
        let busy  = dUser &+ dSystem
        return total > 0 ? Double(busy) / Double(total) : 0
    }

    @discardableResult
    func read(into snap: inout SystemSnapshot) -> Bool {
        let value = usage()
        snap.cpuUsage = value
        return true
    }
}

// MARK: - 内存采样

final class MemorySampler: MetricReading {
    func sample() -> (usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let hostPort = mach_host_self()
        var pageSize: vm_size_t = 0
        host_page_size(hostPort, &pageSize)

        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { rebound in
                host_statistics64(hostPort, HOST_VM_INFO64, rebound, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }

        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let pageBytes = Double(pageSize)
        let usedBytes = Double(active + wired + compressed) * pageBytes

        var memSize: UInt64 = 0
        var memSizeLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0)

        return (usedBytes / 1e9, Double(memSize) / 1e9)
    }

    @discardableResult
    func read(into snap: inout SystemSnapshot) -> Bool {
        let v = sample()
        snap.memUsedGB = v.usedGB
        snap.memTotalGB = v.totalGB
        return true
    }
}

// MARK: - 磁盘采样

final class DiskSampler: MetricReading {
    func sample() -> (usedGB: Double, totalGB: Double) {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return (0, 0) }
        let totalBytes = Double(fs.f_blocks) * Double(fs.f_bsize)
        let freeBytes = Double(fs.f_bfree) * Double(fs.f_bsize)
        let usedBytes = totalBytes - freeBytes
        return (usedBytes / 1e9, totalBytes / 1e9)
    }

    @discardableResult
    func read(into snap: inout SystemSnapshot) -> Bool {
        let v = sample()
        snap.diskUsedGB = v.usedGB
        snap.diskTotalGB = v.totalGB
        return true
    }
}

// MARK: - 网络采样

final class NetworkSampler: MetricReading {
    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0
    private var lastTime: Date = .distantPast

    /// 返回 (KB/s 入, KB/s 出)
    func sample() -> (inKBps: Double, outKBps: Double) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrPtr) }

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = p.pointee.ifa_flags
            let name = String(cString: p.pointee.ifa_name)
            guard name == "en0",
                  (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = p.pointee.ifa_data else { continue }

            let nd = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn  &+= UInt64(nd.ifi_ibytes)
            bytesOut &+= UInt64(nd.ifi_obytes)
        }

        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        var kbpsIn = 0.0, kbpsOut = 0.0
        if lastTime != .distantPast, dt > 0, lastBytesIn > 0 {
            kbpsIn  = Double(bytesIn  - lastBytesIn)  / 1024.0 / dt
            kbpsOut = Double(bytesOut - lastBytesOut) / 1024.0 / dt
        }
        lastBytesIn = bytesIn
        lastBytesOut = bytesOut
        lastTime = now
        return (max(kbpsIn, 0), max(kbpsOut, 0))
    }

    @discardableResult
    func read(into snap: inout SystemSnapshot) -> Bool {
        let v = sample()
        snap.netInKBps = v.inKBps
        snap.netOutKBps = v.outKBps
        return true
    }
}

// MARK: - 状态机

final class SystemMonitor: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    /// 最近 60 秒网络历史（KB/s），供 sparkline 使用
    @Published var netHistory: [NetPoint] = []

    /// 统一 seam 后的采样器集合。
    private let samplers: [MetricReading]
    private let network: NetworkSampler
    private var cancellable: AnyCancellable?

    var cpuColor: Color {
        if snapshot.cpuUsage > 0.85 { return .red }
        if snapshot.cpuUsage > 0.65 { return .orange }
        return .primary
    }

    init() {
        let cpu = CPUSampler()
        let mem = MemorySampler()
        let disk = DiskSampler()
        let net = NetworkSampler()
        self.network = net
        self.samplers = [cpu, mem, disk, net]
    }

    func start() {
        // 用 Combine Timer.publish:它在 main RunLoop 调度,Swift 6 不会因为 actor 隔离争议而静默失败
        cancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                os_log("tick fire", log: log, type: .debug)
                self.tick()
            }
        // 立刻跑一次作为基线
        tick()
    }

    func stop() { cancellable?.cancel(); cancellable = nil }

    private func tick() {
        var snap = snapshot
        for sampler in samplers {
            sampler.read(into: &snap)
        }
        os_log("cpu=%.3f mem=%.2f/%.2f disk=%.2f/%.2f net=%.1f/%.1f",
               log: log, type: .debug,
               snap.cpuUsage, snap.memUsedGB, snap.memTotalGB,
               snap.diskUsedGB, snap.diskTotalGB,
               snap.netInKBps, snap.netOutKBps)

        // netHistory 仍由 monitor 维护：UI 需要最近样本序列，不是单点
        netHistory.append(NetPoint(down: snap.netInKBps, up: snap.netOutKBps))
        if netHistory.count > 60 {
            netHistory.removeFirst(netHistory.count - 60)
        }

        snapshot = snap
    }
}

// MARK: - UI

/// 网络采样点（结构体而非 tuple：onChange(of:) 需要 Equatable）
struct NetPoint: Equatable {
    let down: Double
    let up: Double
}

/// 60 秒网络折线图（下面积 + 上线），Catmull-Rom 平滑 + 插值动画
struct NetSparkline: View {
    let history: [NetPoint]

    @State private var prevHistory: [NetPoint] = []
    @State private var animStart = Date.distantPast
    @State private var isAnimating = false
    private let animDuration: TimeInterval = 0.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let progress: Double = isAnimating
                ? min(context.date.timeIntervalSince(animStart) / animDuration, 1.0)
                : 1.0

            Canvas { ctx, size in
                guard !history.isEmpty, size.width > 1, size.height > 1 else { return }

                // 新旧数据逐点插值：动画进行时曲线从旧形态平滑过渡到新形态
                let interp = interpolated(progress: progress)
                let maxV = max(interp.map(\.down).max() ?? 0, interp.map(\.up).max() ?? 0)
                let peak = max(maxV * 1.15, 10)
                let w = size.width
                let h = size.height
                let stepX = w / CGFloat(max(interp.count - 1, 1))

                func pt(_ i: Int, _ v: Double) -> CGPoint {
                    CGPoint(x: CGFloat(i) * stepX, y: h - CGFloat(min(v, peak)) / CGFloat(peak) * h)
                }

                let downPts = interp.indices.map { pt($0, interp[$0].down) }
                let upPts = interp.indices.map { pt($0, interp[$0].up) }

                // 下行：平滑面积图（渐变填充）
                var area = smoothPath(downPts)
                area.addLine(to: CGPoint(x: w, y: h))
                area.addLine(to: CGPoint(x: 0, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [.green.opacity(0.30), .green.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: h)
                ))

                // 下行：绿色实线；上行：蓝色实线
                ctx.stroke(smoothPath(downPts), with: .color(.green), lineWidth: 1.5)
                ctx.stroke(smoothPath(upPts), with: .color(.blue), lineWidth: 1.5)
            }
        }
        .onChange(of: history) { old, _ in
            prevHistory = old
            animStart = Date()
            isAnimating = true
        }
    }

    /// 对每个数据点在新旧值之间线性插值（对齐索引，缺失按 0 处理）
    private func interpolated(progress: Double) -> [NetPoint] {
        let n = max(history.count, prevHistory.count)
        guard n > 0 else { return [] }
        return (0..<n).map { i in
            let pd = i < prevHistory.count ? prevHistory[i].down : 0
            let cd = i < history.count ? history[i].down : 0
            let pu = i < prevHistory.count ? prevHistory[i].up : 0
            let cu = i < history.count ? history[i].up : 0
            return NetPoint(
                down: pd + (cd - pd) * progress,
                up: pu + (cu - pu) * progress
            )
        }
    }

    /// Catmull-Rom 样条转三次贝塞尔：拐点圆滑，控制点由相邻点推导
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

struct MenuContentView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var quotas: QuotaCoordinator
    @EnvironmentObject var settings: StatusBarSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricRow(icon: "cpu", title: "CPU", pct: monitor.snapshot.cpuUsage,
                      detail: String(format: "%.0f%%", monitor.snapshot.cpuUsage * 100))
            metricRow(icon: "memorychip", title: "内存", pct: monitor.snapshot.memPct,
                      detail: String(format: "%.1f / %.1f GB",
                                     monitor.snapshot.memUsedGB,
                                     monitor.snapshot.memTotalGB))
            metricRow(icon: "internaldrive", title: "磁盘", pct: monitor.snapshot.diskPct,
                      detail: String(format: "%.0f / %.0f GB",
                                     monitor.snapshot.diskUsedGB,
                                     monitor.snapshot.diskTotalGB))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .leading)
                    Text("网络").frame(width: 36, alignment: .leading)
                    Text(String(format: "↓ %.1f KB/s ↑ %.1f KB/s",
                                monitor.snapshot.netInKBps,
                                monitor.snapshot.netOutKBps))
                        .font(.system(.body, design: .monospaced))
                }
                NetSparkline(history: monitor.netHistory)
                    .frame(height: 48)
            }

            Divider()

            // AI Provider：开关关闭的厂商不展示
            if settings.showDeepSeek {
                aiQuotaSection
            }
            if settings.showMiniMax {
                miniMaxSection
            }
            // 统一的刷新 + 配置（刷新两个厂商；配置打开 AI Provider 面板）
            HStack(spacing: 6) {
                Button("刷新") { Task { await quotas.refreshAll() } }
                    .disabled(quotas.isLoading)
                Button("配置") { NotificationCenter.default.post(name: .showAIProviderConfig, object: nil) }
            }
            .controlSize(.small)

            Divider()
            HStack {
                Text(String(format: "刷新1Hz · SysMonBar"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                SettingsLink {
                    Text("设置")
                }
                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20))
    }

    private func metricRow(icon: String, title: String, pct: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .leading)
                Text(title).frame(width: 36, alignment: .leading)
                Text(detail).font(.system(.body, design: .monospaced))
                Spacer()
            }
            ProgressView(value: pct)
                .progressViewStyle(.linear)
                .tint(color(for: pct))
        }
    }

    private func color(for pct: Double) -> Color {
        if pct > 0.85 { return .red }
        if pct > 0.65 { return .orange }
        return .green
    }

    /// 通用 provider 面板 section（图标+名称+进度条/余额+时间；按键统一由面板提供）
    @ViewBuilder
    private func providerSection(_ provider: any ProviderQuota) -> some View {
        VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: provider.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .leading)
                    Text(provider.displayName)
                    // 有 progressSegments 时不显示文本余额（进度条替代）
                    if provider.progressSegments.isEmpty {
                        if provider.isAuthenticated, let bal = provider.balance {
                            Text(verbatim: provider.formatted(bal))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(provider.summaryColor)
                                .fixedSize(horizontal: true, vertical: false)
                        } else if provider.isLoading {
                            ProgressView().controlSize(.small)
                        } else if !provider.isAuthenticated {
                            Text("未设置 Key").foregroundStyle(.secondary)
                        }
                    }
                }
                // 进度条分段（MiniMax：5h + 周限额）
                ForEach(Array(provider.progressSegments.enumerated()), id: \.offset) { _, seg in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(seg.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(seg.percent * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: seg.percent)
                            .progressViewStyle(.linear)
                            .tint(seg.percent > 0.5 ? Color.green : (seg.percent > 0.2 ? Color.orange : Color.red))
                    }
                }
                // 无进度条时才显示副余额文本
                if provider.progressSegments.isEmpty, let secondary = provider.secondaryBalance {
                    Text("周剩余: \(provider.formatted(secondary))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let updated = provider.lastUpdated {
                    Text("更新于 \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let err = provider.lastError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
    }

    private var aiQuotaSection: some View {
        providerSection(quotas.deepSeek)
    }

    private var miniMaxSection: some View {
        providerSection(quotas.miniMax)
    }
}

// MARK: - AI 订阅额度

/// 进度条分段（label + 0.0-1.0 的百分比），provider 自带的多条进度条
struct ProviderProgressSegment {
    let label: String
    let percent: Double
}

protocol ProviderQuota: ObservableObject {
    var name: String { get }
    var displayName: String { get }
    var icon: String { get }
    var currencySymbol: String { get }
    var balance: Decimal? { get }
    /// 副余额（如 MiniMax 的周限额），默认 nil
    var secondaryBalance: Decimal? { get }
    var lastUpdated: Date? { get }
    var isAuthenticated: Bool { get }
    var lastError: String? { get }
    var isLoading: Bool { get }
    var summaryColor: Color { get }
    /// 进度条分段（默认空；MiniMax 暴露 5h/周两条）
    var progressSegments: [ProviderProgressSegment] { get }
    func start()
    func stop()
    func refresh() async
    func signIn() async
    func signOut()
    /// 余额格式化（默认符号在前如 ¥110；MiniMax 覆盖为符号在后如 13%）
    func formatted(_ amount: Decimal) -> String
}

extension ProviderQuota {
    var secondaryBalance: Decimal? { nil }
    var progressSegments: [ProviderProgressSegment] { [] }
    func formatted(_ amount: Decimal) -> String {
        "\(currencySymbol)\(amount)"
    }
}

// MARK: - SQLite 配置存储

/// 通用 SQLite 键值存储（表 kv: key TEXT PRIMARY KEY, value TEXT）
/// 数据库文件位于 ~/Library/Application Support/com.theworld7.sysmonbar/store.sqlite
/// 每次调用都 open/close 连接，低频配置读写足够，无需担心线程安全。
/// Swift 等价于 SQLITE_TRANSIENT_FN：C 宏 ((sqlite3_destructor_type)-1)，
/// 告诉 SQLite 立即拷贝绑定的字符串，Swift String 可以安全释放。
private let SQLITE_TRANSIENT_FN = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteStore {
    let dbURL: URL

    init() {
        let fm = FileManager.default
        let base: URL
        if let support = try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true) {
            base = support
        } else {
            base = fm.temporaryDirectory  // 极端 fallback
        }
        let dir = base.appendingPathComponent("com.theworld7.sysmonbar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbURL = dir.appendingPathComponent("store.sqlite")
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else { return nil }
        // 建表（IF NOT EXISTS，幂等）
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);",
                     nil, nil, nil)
        return db
    }

    func load(_ key: String) -> String? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM kv WHERE key = ? LIMIT 1;",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_FN)
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    func save(_ key: String, value: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?);",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT_FN)
        sqlite3_step(stmt)
    }

    func delete(_ key: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "DELETE FROM kv WHERE key = ?;",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT_FN)
        sqlite3_step(stmt)
    }

    func getBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let s = load(key) else { return defaultValue }
        return s == "1"
    }

    func setBool(_ key: String, _ value: Bool) {
        save(key, value: value ? "1" : "0")
    }
}

/// DeepSeek API Key 持久化（SQLite 后端）
struct DeepSeekAPIKeyStore {
    private static let db = SQLiteStore()
    private static let rowKey = "deepseek_api_key"

    func load() -> String? {
        Self.db.load(Self.rowKey)
    }

    func save(_ value: String) {
        Self.db.save(Self.rowKey, value: value)
    }

    func clear() {
        Self.db.delete(Self.rowKey)
    }
}

/// MiniMax API Key 持久化（SQLite 后端）
struct MiniMaxAPIKeyStore {
    private static let db = SQLiteStore()
    private static let rowKey = "minimax_api_key"

    func load() -> String? { Self.db.load(Self.rowKey) }
    func save(_ value: String) { Self.db.save(Self.rowKey, value: value) }
    func clear() { Self.db.delete(Self.rowKey) }
}

// MARK: - DeepSeek 官方余额 API

/// 官方 GET https://api.deepseek.com/user/balance 的返回结构。
/// 字段说明：is_available=余额是否足够调用；balance_infos 为各币种余额：
/// total_balance=总可用余额（赠金+充值），granted_balance=未过期赠金，
/// topped_up_balance=充值余额。
struct DeepSeekBalance: Decodable {
    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }

    struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: Decimal
        let grantedBalance: Decimal
        let toppedUpBalance: Decimal

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currency = try c.decode(String.self, forKey: .currency)
            totalBalance = try c.flexibleDecimal(forKey: .totalBalance)
            grantedBalance = try c.flexibleDecimal(forKey: .grantedBalance)
            toppedUpBalance = try c.flexibleDecimal(forKey: .toppedUpBalance)
        }
    }
}

/// MiniMax GET /v1/token_plan/remains 真实返回结构
/// base_resp 包含业务状态（status_code == 0 才算成功），model_remains 是各模型限额
struct MiniMaxBalance: Decodable {
    let modelRemains: [ModelRemain]
    let baseResp: BaseResp

    enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }

    struct BaseResp: Decodable {
        let statusCode: Int
        let statusMsg: String

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMsg = "status_msg"
        }

        var isSuccess: Bool { statusCode == 0 }
    }

    struct ModelRemain: Decodable {
        let currentIntervalRemainingPercent: Int   // 5h 已使用百分比 0-100（接口实为已用额度）
        let currentWeeklyRemainingPercent: Int     // 周已使用百分比 0-100
        let modelName: String?

        enum CodingKeys: String, CodingKey {
            case currentIntervalRemainingPercent = "current_interval_remaining_percent"
            case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
            case modelName = "model_name"
        }
    }
}

private extension KeyedDecodingContainer {
    /// 兼容 API 用字符串（"110.00"）或数字（110.0）返回金额。
    func flexibleDecimal(forKey key: Key) throws -> Decimal {
        if let s = try? decode(String.self, forKey: key),
           let d = Decimal(string: s) {
            return d
        }
        return try decode(Decimal.self, forKey: key)
    }
}

@MainActor
enum APIKeyInputAlert {
    /// 通用 API Key 输入弹窗。messageText 为标题，informativeText 为说明。
    static func present(
        messageText: String,
        informativeText: String = "余额将通过官方接口查询。",
        placeholder: String = "sk-...",
        onSubmit: @escaping (String?) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        let key = response == .alertFirstButtonReturn
            ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        onSubmit(key)
    }
}

@MainActor
final class DeepSeekProvider: ObservableObject, ProviderQuota {
    let name = "DeepSeek"
    let displayName = "DeepSeek"
    let icon = "creditcard"
    var currencySymbol: String { currency == "USD" ? "$" : "¥" }
    @Published private(set) var currency = "CNY"

    /// >¥100 绿、¥20–100 橙、<¥20 红
    var summaryColor: Color {
        guard let bal = balance else { return .secondary }
        let n = NSDecimalNumber(decimal: bal).doubleValue
        if n > 100 { return .green }
        if n > 20 { return .orange }
        return .red
    }

    @Published private(set) var balance: Decimal?
    @Published private(set) var isAvailable = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    /// 内存中的 API Key 缓存，避免每次 refresh 都访问 Keychain
    private var cachedAPIKey: String?
    private let store = DeepSeekAPIKeyStore()
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300  // 5 分钟
    private let apiURL = URL(string: "https://api.deepseek.com/user/balance")!

    init() {
        // 注：不要在这里设 isAuthenticated。SwiftUI App.init() 返回后 SwiftUI 才订阅
        // objectWillChange，init 里的 @Published 赋值不会被观测到。
        // 初始状态同步在 start() 里做（那时 SwiftUI 已订阅）。
    }

    /// 从 Keychain 重新读取 API Key 状态，同步给 SwiftUI。
    /// 必须在 start() 里调用，因为 SwiftUI 在 init 完成后才订阅 ObservableObject。
    private func syncAuthFromStore() {
        let key = store.load()
        cachedAPIKey = key
        let has = key?.isEmpty == false
        if isAuthenticated != has { isAuthenticated = has }
    }

    func start() {
        syncAuthFromStore()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        // 不再 guard isAuthenticated：只要 Keychain 里有 API Key 就尝试拉数据，
        // 拉不到（401/网络错误）再清状态。这样首次启动也能恢复已登录态。
        isLoading = true
        defer { isLoading = false }

        let key: String
        if let cached = cachedAPIKey, !cached.isEmpty {
            key = cached
        } else if let loaded = store.load(), !loaded.isEmpty {
            cachedAPIKey = loaded
            key = loaded
        } else {
            if isAuthenticated { isAuthenticated = false }
            lastError = "未设置 API Key，请先设置密钥"
            return
        }
        if !isAuthenticated { isAuthenticated = true }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastError = "无效响应"
                return
            }
            // 401 → API Key 无效或已被吊销
            if http.statusCode == 401 {
                isAuthenticated = false
                lastError = "API Key 无效，请重新设置"
                store.clear()
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }

            do {
                let payload = try JSONDecoder().decode(DeepSeekBalance.self, from: data)
                guard !payload.balanceInfos.isEmpty else {
                    lastError = "未返回余额信息"
                    return
                }
                // 优先人民币（CNY）币种，找不到再取第一条。
                let info = payload.balanceInfos.first { $0.currency.contains("CNY") }
                    ?? payload.balanceInfos[0]
                // 展示总可用余额（赠金 + 充值）。如需只看充值，改用 toppedUpBalance。
                currency = info.currency
                balance = info.totalBalance
                isAvailable = payload.isAvailable
                lastUpdated = Date()
                lastError = nil
            } catch {
                lastError = "解析余额失败：\(error.localizedDescription)"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signIn() async {
        APIKeyInputAlert.present(
            messageText: "设置 DeepSeek API Key",
            informativeText: "在 platform.deepseek.com 的 \"API Keys\" 页面生成密钥。余额将通过官方 /user/balance 接口查询。"
        ) { [weak self] key in
            guard let self, let key, !key.isEmpty else { return }
            self.store.save(key)
            self.cachedAPIKey = key
            self.isAuthenticated = true
            self.lastError = nil
            Task { await self.refresh() }
        }
    }

    func signOut() {
        store.clear()
        cachedAPIKey = nil
        isAuthenticated = false
        balance = nil
        isAvailable = false
        currency = "CNY"
        lastUpdated = nil
        lastError = nil
    }

    /// 当前已保存的 API Key（用于配置界面回填）
    var storedAPIKey: String? { store.load() }

    /// 直接保存 API Key（配置界面输入框使用），不弹窗
    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.save(trimmed)
        cachedAPIKey = trimmed
        isAuthenticated = true
        lastError = nil
        Task { await refresh() }
    }
}

@MainActor
final class MiniMaxProvider: ObservableObject, ProviderQuota {
    let name = "MiniMax"
    let displayName = "MiniMax"
    let icon = "bolt"
    let currencySymbol = "%"

    /// 剩余百分比：>50 绿、>20 橙、其余红
    var summaryColor: Color {
        guard let bal = balance else { return .secondary }
        let n = NSDecimalNumber(decimal: bal).doubleValue
        if n > 50 { return .green }
        if n > 20 { return .orange }
        return .red
    }

    /// 百分比符号在后：「13%」
    func formatted(_ amount: Decimal) -> String {
        "\(amount)\(currencySymbol)"
    }

    /// 5h / 周剩余百分比的进度条（接口返回已用额度，这里换算成剩余显示）
    var progressSegments: [ProviderProgressSegment] {
        guard let b5h = balance, let bw = secondaryBalance else { return [] }
        return [
            ProviderProgressSegment(label: "5h 剩余", percent: NSDecimalNumber(decimal: b5h).doubleValue / 100.0),
            ProviderProgressSegment(label: "周剩余", percent: NSDecimalNumber(decimal: bw).doubleValue / 100.0),
        ]
    }

    @Published private(set) var balance: Decimal?
    /// 周剩余百分比（副余额）
    @Published private(set) var weeklyBalance: Decimal?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    private var cachedAPIKey: String?
    private let store = MiniMaxAPIKeyStore()
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300
    private let apiURL = URL(string: "https://api.minimaxi.com/v1/token_plan/remains")!

    init() {}

    private func syncAuthFromStore() {
        let key = store.load()
        cachedAPIKey = key
        let has = key?.isEmpty == false
        if isAuthenticated != has { isAuthenticated = has }
    }

    func start() {
        syncAuthFromStore()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let key: String
        if let cached = cachedAPIKey, !cached.isEmpty {
            key = cached
        } else if let loaded = store.load(), !loaded.isEmpty {
            cachedAPIKey = loaded
            key = loaded
        } else {
            if isAuthenticated { isAuthenticated = false }
            lastError = "未设置 API Key，请先设置密钥"
            return
        }
        if !isAuthenticated { isAuthenticated = true }

        var req = URLRequest(url: apiURL)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastError = "无效响应"
                return
            }
            if http.statusCode == 401 {
                isAuthenticated = false
                lastError = "API Key 无效，请重新设置"
                store.clear()
                cachedAPIKey = nil
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }

            do {
                let payload = try JSONDecoder().decode(MiniMaxBalance.self, from: data)
                guard payload.baseResp.isSuccess else {
                    lastError = "API: \(payload.baseResp.statusMsg)"
                    return
                }
                // 接口返回的是已使用额度，换算成剩余额度显示（100 - 已用）
                balance = payload.modelRemains.first.map { Decimal(100 - $0.currentIntervalRemainingPercent) } ?? 0
                weeklyBalance = payload.modelRemains.first.map { Decimal(100 - $0.currentWeeklyRemainingPercent) } ?? 0
                lastUpdated = Date()
                lastError = nil
            } catch {
                lastError = "解析余额失败：\(error.localizedDescription)"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 周剩余百分比作为副余额展示
    var secondaryBalance: Decimal? { weeklyBalance }

    func signIn() async {
        APIKeyInputAlert.present(
            messageText: "设置 MiniMax API Key",
            informativeText: "在 platform.MiniMax.io 的 API Keys 页面生成密钥。余额将通过 /v1/token_plan/remains 接口查询。"
        ) { [weak self] key in
            guard let self, let key, !key.isEmpty else { return }
            self.store.save(key)
            self.cachedAPIKey = key
            self.isAuthenticated = true
            self.lastError = nil
            Task { await self.refresh() }
        }
    }

    func signOut() {
        store.clear()
        cachedAPIKey = nil
        isAuthenticated = false
        balance = nil
        weeklyBalance = nil
        lastUpdated = nil
        lastError = nil
    }

    /// 当前已保存的 API Key（用于配置界面回填）
    var storedAPIKey: String? { store.load() }

    /// 直接保存 API Key（配置界面输入框使用），不弹窗
    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.save(trimmed)
        cachedAPIKey = trimmed
        isAuthenticated = true
        lastError = nil
        Task { await refresh() }
    }
}

@MainActor
final class QuotaCoordinator: ObservableObject {
    let providers: [any ProviderQuota]
    let deepSeek: DeepSeekProvider
    let miniMax: MiniMaxProvider

    init() {
        let ds = DeepSeekProvider()
        let mm = MiniMaxProvider()
        self.deepSeek = ds
        self.miniMax = mm
        self.providers = [ds, mm]
    }

    func start() {
        for p in providers { p.start() }
    }

    func stop() {
        for p in providers { p.stop() }
    }

    /// 任一厂商是否正在加载（用于禁用“刷新”按钮）
    var isLoading: Bool {
        providers.contains { $0.isLoading }
    }

    /// 一次刷新所有厂商（DeepSeek + MiniMax）
    func refreshAll() async {
        await deepSeek.refresh()
        await miniMax.refresh()
    }

    /// 菜单栏展示用的简短文本（已登录且有余额时才有意义）
    var summary: String {
        guard let bal = deepSeek.balance else { return "—" }
        return "\(deepSeek.currencySymbol)\(bal)"
    }

    /// 菜单栏用的颜色（兼容旧引用，委托给 deepSeek）
    var summaryColor: Color { deepSeek.summaryColor }
}

// MARK: - App 入口

// 共享全局状态：App 与 AppDelegate 都需要访问 monitor / quotas
@MainActor
final class StatusBarSettings: ObservableObject {
    @Published var showCPU: Bool      { didSet { store.setBool("statusbar.show_cpu", showCPU) } }
    @Published var showMemory: Bool   { didSet { store.setBool("statusbar.show_memory", showMemory) } }
    @Published var showDisk: Bool     { didSet { store.setBool("statusbar.show_disk", showDisk) } }
    @Published var showDeepSeek: Bool { didSet { store.setBool("statusbar.show_deepseek", showDeepSeek) } }
    @Published var showMiniMax: Bool  { didSet { store.setBool("statusbar.show_minimax", showMiniMax) } }

    private let store = SQLiteStore()

    init() {
        showCPU      = store.getBool("statusbar.show_cpu", default: true)
        showMemory   = store.getBool("statusbar.show_memory", default: true)
        showDisk     = store.getBool("statusbar.show_disk", default: true)
        showDeepSeek = store.getBool("statusbar.show_deepseek", default: true)
        showMiniMax  = store.getBool("statusbar.show_minimax", default: true)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: StatusBarSettings

    var body: some View {
        Form {
            Section("状态栏显示项") {
                Toggle("CPU 使用率", isOn: $settings.showCPU)
                Toggle("内存", isOn: $settings.showMemory)
                Toggle("磁盘", isOn: $settings.showDisk)
                Toggle("DeepSeek 余额", isOn: $settings.showDeepSeek)
                Toggle("MiniMax 余额", isOn: $settings.showMiniMax)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// AI Provider 配置面板（独立窗口）：每个厂商一行（名称 + Switch 开关），
/// 打开后展示 API Key 输入框。关闭开关只隐藏展示，不删除已保存的 Key。
/// 通过“保存/取消”统一提交，避免边改边生效。
struct AIProviderConfigView: View {
    let settings: StatusBarSettings
    let deepSeek: DeepSeekProvider
    let miniMax: MiniMaxProvider
    let onSave: () -> Void
    let onCancel: () -> Void
    @State private var dsEnabled: Bool
    @State private var mmEnabled: Bool
    @State private var dsKey: String
    @State private var mmKey: String

    init(
        settings: StatusBarSettings,
        deepSeek: DeepSeekProvider,
        miniMax: MiniMaxProvider,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.settings = settings
        self.deepSeek = deepSeek
        self.miniMax = miniMax
        self.onSave = onSave
        self.onCancel = onCancel
        _dsEnabled = State(initialValue: settings.showDeepSeek)
        _mmEnabled = State(initialValue: settings.showMiniMax)
        _dsKey = State(initialValue: deepSeek.storedAPIKey ?? "")
        _mmKey = State(initialValue: miniMax.storedAPIKey ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Provider 配置")
                .font(.headline)

            providerRow(title: "DeepSeek", enabled: $dsEnabled, key: $dsKey,
                        placeholder: "DeepSeek API Key (sk-...)")

            Divider()

            providerRow(title: "MiniMax", enabled: $mmEnabled, key: $mmKey,
                        placeholder: "MiniMax API Key (sk-...)")

            Divider()

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { apply(); onSave() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding()
        .frame(width: 400)
    }

    @ViewBuilder
    private func providerRow(
        title: String,
        enabled: Binding<Bool>,
        key: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Toggle("", isOn: enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if enabled.wrappedValue {
                TextField(placeholder, text: key)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
    }

    /// 统一提交：应用到显示开关 + 保存各厂商 Key（仅对打开的厂商写入）
    private func apply() {
        settings.showDeepSeek = dsEnabled
        settings.showMiniMax = mmEnabled
        if dsEnabled {
            let dk = dsKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !dk.isEmpty { deepSeek.saveAPIKey(dk) }
        }
        if mmEnabled {
            let mk = mmKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mk.isEmpty { miniMax.saveAPIKey(mk) }
        }
    }
}

@MainActor
final class AppState {
    let monitor = SystemMonitor()
    let quotas = QuotaCoordinator()
    let settings = StatusBarSettings()
    init() { monitor.start(); quotas.start() }
}

// 状态栏标签（原 MenuBarExtra label 抽出，方便 NSHostingView 托管）
struct StatusBarLabel: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var quotas: QuotaCoordinator
    @ObservedObject var settings: StatusBarSettings

    var body: some View {
        HStack(spacing: 6) {
            if settings.showCPU {
                Image(systemName: "cpu")
                    .foregroundStyle(monitor.cpuColor)
                Text("\(Int(monitor.snapshot.cpuUsage * 100))%")
                    .foregroundStyle(monitor.cpuColor)
            }

            if settings.showMemory {
                Image(systemName: "memorychip")
                    .foregroundStyle(.secondary)
                Text("\(Int(monitor.snapshot.memUsedGB))/\(Int(monitor.snapshot.memTotalGB))G")
                    .foregroundStyle(.secondary)
            }

            if settings.showDisk {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("\(Int(monitor.snapshot.diskPct * 100))%")
                    .foregroundStyle(.secondary)
            }

            if settings.showDeepSeek && quotas.deepSeek.isAuthenticated, let bal = quotas.deepSeek.balance {
                Image(systemName: quotas.deepSeek.icon + ".fill")
                    .foregroundStyle(quotas.deepSeek.summaryColor)
                Text(quotas.deepSeek.formatted(bal))
                    .foregroundStyle(quotas.deepSeek.summaryColor)
            }

            if settings.showMiniMax && quotas.miniMax.isAuthenticated, let bal = quotas.miniMax.balance {
                Image(systemName: quotas.miniMax.icon + ".fill")
                    .foregroundStyle(quotas.miniMax.summaryColor)
                Text(quotas.miniMax.formatted(bal))
                    .foregroundStyle(quotas.miniMax.summaryColor)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .fixedSize()
    }
}

// 弹窗视图控制器：根视图是 NSGlassEffectView（系统 Liquid Glass 容器），
// 内容用 NSHostingView 托管 SwiftUI 面板。这样系统「外观→Liquid Glass」滑块
// 能直接作用在 NSGlassEffectView 上，不受 NSHostingView 限制。
final class PanelViewController: NSViewController {
    let monitor: SystemMonitor
    let quotas: QuotaCoordinator
    let settings: StatusBarSettings

    init(monitor: SystemMonitor, quotas: QuotaCoordinator, settings: StatusBarSettings) {
        self.monitor = monitor
        self.quotas = quotas
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = NSSize(width: 360, height: 400)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = container

        let hosting = NSHostingView(rootView:
            MenuContentView()
                .environmentObject(monitor)
                .environmentObject(quotas)
                .environmentObject(settings)
                .frame(width: 360)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let win = self.view.window else { return }
        // NSPopover 默认会给弹窗窗口套一圈 drop shadow；控制中心风格的玻璃面板不需要
        win.hasShadow = false
        // 确保弹窗窗口自身透明，不挡底层玻璃的透光
        win.backgroundColor = .clear
        win.isOpaque = false
    }
}

extension Notification.Name {
    static let showAIProviderConfig = Notification.Name("showAIProviderConfig")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let state = AppState()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var configWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        os_log("app did finish launching", log: log, type: .info)
        NotificationCenter.default.addObserver(self, selector: #selector(handleShowProviderConfig(_:)),
                                               name: .showAIProviderConfig, object: nil)
        setupStatusItemAndPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        os_log("app will terminate", log: log, type: .info)
        state.monitor.stop()
        state.quotas.stop()
    }

    private func setupStatusItemAndPopover() {
        // 状态栏：NSStatusItem + NSButton，button 内嵌 NSHostingView(SwiftUI 标签)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let label = NSHostingView(rootView:
            StatusBarLabel(monitor: state.monitor, quotas: state.quotas, settings: state.settings)
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            label.topAnchor.constraint(equalTo: button.topAnchor),
            label.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        button.action = #selector(togglePopover(_:))
        button.target = self

        // 弹窗：NSPopover + PanelViewController（自带 NSGlassEffectView）
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 360, height: 400)
        pop.contentViewController = PanelViewController(
            monitor: state.monitor, quotas: state.quotas, settings: state.settings
        )

        self.statusItem = item
        self.popover = pop
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let item = statusItem, let pop = popover, let button = item.button else { return }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - AI Provider 配置窗口
    @objc private func handleShowProviderConfig(_ note: Notification) {
        showProviderConfig()
    }

    /// 打开/聚焦 AI Provider 配置窗口（独立窗口，可统一保存/取消）
    func showProviderConfig() {
        if let win = configWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "AI Provider 配置"
        win.isReleasedWhenClosed = false
        win.delegate = self

        let content = AIProviderConfigView(
            settings: state.settings,
            deepSeek: state.quotas.deepSeek,
            miniMax: state.quotas.miniMax,
            onSave: { [weak self] in self?.closeProviderConfig() },
            onCancel: { [weak self] in self?.closeProviderConfig() }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        win.contentView = container
        win.center()

        self.configWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeProviderConfig() {
        configWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win === configWindow else { return }
        configWindow = nil
    }
}

@main
struct SysMonBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: appDelegate.state.settings)
        }
    }
}
