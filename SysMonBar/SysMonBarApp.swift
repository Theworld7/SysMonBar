//
// SysMonBarApp.swift
//  SysMonBar — 单文件版菜单栏系统监控
//  macOS 13+ · Swift 5.9+ / Swift 6 兼容
//

import SwiftUI
import Combine
import Darwin
import WebKit
import Security
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

            // 注：macOS 26+ 内核 getifaddrs 返回的是 if_data64（u_int64_t 字节计数器），
            // 旧的 if_data (u_int32_t) 在 SDK 已废弃。读错结构体会拿到错偏移上的数据，
            // 后续 Double(bytesIn - lastBytesIn) 会因为极大值触发 arithmetic overflow trap。
            let nd = data.assumingMemoryBound(to: if_data64.self).pointee
            bytesIn  &+= nd.ifi_ibytes
            bytesOut &+= nd.ifi_obytes
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
                        .frame(width: 36, alignment: .leading)
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

            aiQuotaSection

            Divider()
            HStack {
                Text(String(format: "刷新1Hz · SysMonBar"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
    }

    private func metricRow(icon: String, title: String, pct: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
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

    @ViewBuilder
    private var aiQuotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "creditcard")
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
                Text("AI 余额").frame(width: 36, alignment: .leading)
                if quotas.deepSeek.isAuthenticated {
                    if let bal = quotas.deepSeek.balance {
                        Text(verbatim: "\(quotas.deepSeek.currencySymbol)\(bal)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(quotas.summaryColor)
                    } else if quotas.deepSeek.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                } else {
                    Text("未登录").foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let updated = quotas.deepSeek.lastUpdated {
                Text("更新于 \(updated.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let err = quotas.deepSeek.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                if quotas.deepSeek.isAuthenticated {
                    Button("刷新") {
                        Task { await quotas.deepSeek.refresh() }
                    }
                    .disabled(quotas.deepSeek.isLoading)
                    Button("退出登录") {
                        quotas.deepSeek.signOut()
                    }
                } else {
                    Button("登录 DeepSeek") {
                        Task { await quotas.deepSeek.signIn() }
                    }
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

// MARK: - AI 订阅额度

protocol ProviderQuota: ObservableObject {
    var name: String { get }
    var displayName: String { get }
    var currencySymbol: String { get }
    var balance: Decimal? { get }
    var lastUpdated: Date? { get }
    var isAuthenticated: Bool { get }
    var lastError: String? { get }
    var isLoading: Bool { get }
    func start()
    func stop()
    func refresh() async
    func signIn() async
    func signOut()
}

/// Keychain 存取 DeepSeek 登录 cookie（plain JSON 序列化，无 kSecAttrAccessible 限制）
struct DeepSeekCookieStore {
    let service = "com.theworld7.sysmonbar.deepseek"
    let account = "session"

    func load() -> [HTTPCookie] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let props = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return props.compactMap { dict -> HTTPCookie? in
            var typed: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in dict {
                typed[HTTPCookiePropertyKey(rawValue: k)] = v
            }
            return HTTPCookie(properties: typed)
        }
    }

    func save(_ cookies: [HTTPCookie]) {
        let payload = cookies.map { $0.properties ?? [:] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class DeepSeekProvider: ObservableObject, ProviderQuota {
    let name = "DeepSeek"
    let displayName = "DeepSeek"
    let currencySymbol = "¥"

    @Published private(set) var balance: Decimal?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    private let store = DeepSeekCookieStore()
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300  // 5 分钟
    private let balanceURL = URL(string: "https://platform.deepseek.com/usage")!

    init() {
        let cached = store.load()
        isAuthenticated = !cached.isEmpty
    }

    func start() {
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
        guard isAuthenticated else { return }
        isLoading = true
        defer { isLoading = false }

        let cookies = store.load()
        guard !cookies.isEmpty else {
            isAuthenticated = false
            lastError = "登录信息丢失，请重新登录"
            return
        }

        var req = URLRequest(url: balanceURL)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let fields = HTTPCookie.requestHeaderFields(with: cookies)
        for (k, v) in fields { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastError = "无效响应"
                return
            }
            // 401/403 或重定向到登录 → cookie 失效
            if http.statusCode == 401 || http.statusCode == 403 {
                isAuthenticated = false
                lastError = "登录已过期，请重新登录"
                store.clear()
                return
            }
            if let loc = http.value(forHTTPHeaderField: "Location"),
               loc.lowercased().contains("login") || loc.lowercased().contains("sign-in") {
                isAuthenticated = false
                lastError = "登录已过期，请重新登录"
                store.clear()
                return
            }
            guard http.statusCode == 200 else {
                lastError = "HTTP \(http.statusCode)"
                return
            }

            let html = String(data: data, encoding: .utf8) ?? ""
            guard let amount = parseBalance(from: html) else {
                lastError = "解析余额失败（页面结构可能已变更）"
                return
            }
            balance = amount
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signIn() async {
        DeepSeekSignInWindow.present { [weak self] cookies in
            guard let self else { return }
            self.store.save(cookies)
            self.isAuthenticated = true
            self.lastError = nil
            Task { await self.refresh() }
        }
    }

    func signOut() {
        store.clear()
        isAuthenticated = false
        balance = nil
        lastUpdated = nil
        lastError = nil
    }

    /// 从 DeepSeek `/usage` 页面 HTML 里解析「充值余额」金额。
    ///
    /// 页面结构（2025-09 采样）：
    ///   <div data-usage-layout-card="true">
    ///     <span>充值余额</span>          <!-- 卡片标题 -->
    ///     ...
    ///     <span data-usage-layout-font="value">¥6.00</span>
    ///     <span data-usage-layout-font="unit">CNY</span>
    ///   </div>
    ///
    /// 锚点选择：class 名是 styled-components 风格的 hash（不稳定），
    /// 但 `data-usage-layout-*` 属性和中文标签文本是稳定 API。
    ///
    /// 策略：先定位「充值余额」文本，从它向前找最近的 card 边界，
    /// 再在 card 范围内找 value span，提取数字。
    func parseBalance(from html: String) -> Decimal? {
        guard let labelRange = html.range(of: "充值余额") else { return nil }
        let beforeLabel = html[..<labelRange.lowerBound]

        // 向前找最近的 card 边界
        guard let cardAttrRange = beforeLabel.range(
            of: "data-usage-layout-card=\"true\"",
            options: .backwards
        ) else { return nil }

        // 从 card 开始到 HTML 末尾，取第一个 value span
        let cardRegion = html[cardAttrRange.lowerBound...]
        guard let valueAttrRange = cardRegion.range(
            of: "data-usage-layout-font=\"value\""
        ) else { return nil }

        // value span 起始标签结束位置之后的文本即为金额
        let afterValueAttr = cardRegion[valueAttrRange.upperBound...]
        guard let openTagEnd = afterValueAttr.range(of: ">") else { return nil }
        let afterOpenTag = afterValueAttr[openTagEnd.upperBound...]
        guard let closeTag = afterOpenTag.range(of: "</span>") else { return nil }

        let raw = String(afterOpenTag[..<closeTag.lowerBound])
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)

        return Decimal(string: raw)
    }
}

/// WKWebView 内嵌登录窗口，登录成功（URL 离开登录域 + 拿到 session cookie）后回调
final class DeepSeekSignInWindow: NSWindowController, WKNavigationDelegate {
    private var webView: WKWebView!
    private let onSuccess: ([HTTPCookie]) -> Void
    private var completed = false

    private init(onSuccess: @escaping ([HTTPCookie]) -> Void) {
        self.onSuccess = onSuccess

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 680),
            configuration: cfg
        )
        self.webView = webView

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "登录 DeepSeek"
        win.contentView = webView
        win.center()
        win.isReleasedWhenClosed = false

        super.init(window: win)
        webView.navigationDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @MainActor
    static func present(onSuccess: @escaping ([HTTPCookie]) -> Void) {
        let ctrl = DeepSeekSignInWindow(onSuccess: onSuccess)
        ctrl.showWindow(nil)
        ctrl.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let url = URL(string: "https://platform.deepseek.com/login") {
            ctrl.webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !completed, let url = webView.url else { return }
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""

        guard host.contains("deepseek.com") else { return }
        if path.contains("/login") || path.contains("/sign-in") { return }

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.completed else { return }
            let dsCookies = cookies.filter { $0.domain.contains("deepseek.com") }
            guard !dsCookies.isEmpty else { return }
            // 保险：必须有 session/token/user/auth 命名的 cookie 才算登录成功
            let hasSession = dsCookies.contains { c in
                let n = c.name.lowercased()
                return n.contains("session") || n.contains("token") || n.contains("user") || n.contains("auth")
            }
            guard hasSession else { return }

            DispatchQueue.main.async {
                self.completed = true
                self.close()
                self.onSuccess(dsCookies)
            }
        }
    }
}

@MainActor
final class QuotaCoordinator: ObservableObject {
    let providers: [any ProviderQuota]
    let deepSeek: DeepSeekProvider

    init() {
        let ds = DeepSeekProvider()
        self.deepSeek = ds
        self.providers = [ds]
    }

    func start() {
        for p in providers { p.start() }
    }

    func stop() {
        for p in providers { p.stop() }
    }

    /// 菜单栏展示用的简短文本（已登录且有余额时才有意义）
    var summary: String {
        guard let bal = deepSeek.balance else { return "—" }
        return "\(deepSeek.currencySymbol)\(bal)"
    }

    /// 按绝对余额分级：>¥100 绿、¥20–100 橙、<¥20 红
    /// TODO: 用户可按偏好调阈值
    var summaryColor: Color {
        guard let bal = deepSeek.balance else { return .secondary }
        let n = NSDecimalNumber(decimal: bal).doubleValue
        if n > 100 { return .green }
        if n > 20 { return .orange }
        return .red
    }
}

// MARK: - App 入口

@main
struct SysMonBarApp: App {
    @StateObject private var monitor: SystemMonitor
    @StateObject private var quotas: QuotaCoordinator

    init() {
        // 双保险：除了 LSUIElement，运行时再设一次 accessory 激活策略
        // 防止 macOS Sonoma+ 在某些场景下把它当 regular app 处理
        NSApp.setActivationPolicy(.accessory)
        let m = SystemMonitor()
        m.start()
        let q = QuotaCoordinator()
        q.start()
        _monitor = StateObject(wrappedValue: m)
        _quotas = StateObject(wrappedValue: q)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        os_log("app did finish launching", log: log, type: .info)
    }

    func applicationWillTerminate(_ notification: Notification) {
        os_log("app will terminate", log: log, type: .info)
        monitor.stop()
        quotas.stop()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
                .environmentObject(quotas)
                .frame(width: 300)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(monitor.cpuColor)
                Text("\(Int(monitor.snapshot.cpuUsage * 100))%")
                    .foregroundStyle(monitor.cpuColor)

                Image(systemName: "memorychip")
                    .foregroundStyle(.secondary)
                Text("\(Int(monitor.snapshot.memUsedGB))/\(Int(monitor.snapshot.memTotalGB))G")
                    .foregroundStyle(.secondary)

                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("\(Int(monitor.snapshot.diskPct * 100))%")
                    .foregroundStyle(.secondary)

                if quotas.deepSeek.isAuthenticated {
                    Image(systemName: "creditcard.fill")
                        .foregroundStyle(quotas.summaryColor)
                    Text(quotas.summary)
                        .foregroundStyle(quotas.summaryColor)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .fixedSize()
        }
        .menuBarExtraStyle(.window)
    }
}