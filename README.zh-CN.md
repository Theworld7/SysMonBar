# SysMonBar

一个轻量的 macOS 菜单栏应用，把 **系统资源**（CPU / 内存 / 磁盘 / 网络）和 **AI 订阅额度**（DeepSeek / MiniMax）集中在一个面板里实时展示。

常驻菜单栏，不占 Dock 图标。

📖 **[English](README.md)**

## 安装

从 [最新发布](../../releases/latest) 下载 `SysMonBar-v<版本>.zip`，解压，把 `SysMonBar.app` 拖到 `/Applications`。

**首次启动**：macOS 会拦截（"来自身份不明的开发者"）。打开 **系统设置 → 隐私与安全性**，向下滚动，点 SysMonBar 旁边的 **仍要打开**。

## 功能

### 系统资源
- **CPU** —— 实时百分比，带颜色（绿 / 橙 / 红 随负载升高）
- **内存** —— 已用 / 总量 GB
- **磁盘** —— 已用百分比（启动盘）
- **网络** —— 上下行 KB/s + 60 秒平滑曲线（带动画）

### AI 订阅额度
- **DeepSeek** —— 通过 `GET /user/balance` 查询剩余余额（CNY / USD），支持低余额预警阈值。
- **MiniMax** —— 通过 `GET /v1/token_plan/remains` 查询 5 小时和每周的 *已使用* 百分比。接口返回的是剩余百分比，面板在显示时换算为 **剩余 = 100 − 已用**。详见 [`docs/adr/0001`](docs/adr/0001-minimax-balance-semantics.md)。
- 两个厂商都后台轮询（每 5 分钟一次），面板上点一次 **刷新** 会同时拉取两家。

### 面板
- 一个 **刷新** 按钮，一次性刷新 DeepSeek 和 MiniMax 两家数据。
- 一个 **配置** 按钮，打开独立窗口（`AI Provider 配置`），每个厂商一行：
  - 左侧厂商名称，右侧 **Switch 开关**。
  - 打开开关后下方出现输入框，可填写或修改 API Key。
  - **总控开关**：关闭后该厂商的行在面板、状态栏中都不再出现；设置里对应的显隐开关也会被禁用；**已保存的 Key 不会丢失**，再次打开开关即可恢复显示。
  - **预警阈值**：当余额命中用户配置的阈值时，面板主文本会变红（DeepSeek：`balance ≤ 阈值`；MiniMax：`balance ≥ 阈值`，因为 MiniMax 显示的是剩余额度）。

### 状态栏
- 可在 **系统设置 → SysMonBar → 设置** 中按指标逐项开启 / 关闭（CPU / 内存 / 磁盘 / DeepSeek / MiniMax）。
- 总控开关关闭的厂商，状态栏里也不会出现。

## 构建

```bash
./build.sh              # 构建 + 注入图标 + 生成 zip
./build.sh --no-zip     # 只构建 + 注入图标
```

产物：`build/Build/Products/Release/SysMonBar.app` 和 `SysMonBar-v<版本>.zip`。

需要 macOS 与 Xcode（项目设置 `MACOSX_DEPLOYMENT_TARGET = 27.0`）。

## 注意事项

- 仅 ad-hoc 本地签名，未公证。不可发布到 App Store 或 Homebrew Cask。
- 采样 API 适用于 macOS 13+。
- CPU 采样依赖近期 macOS 上 `HOST_CPU_LOAD_INFO` 的未文档化布局，详见 `SysMonBarApp.swift` 注释。
- API Key 保存在本机 SQLite KV 存储中（位于 `~/Library/Application Support/`）。除了向对应厂商的官方接口发送只读查询，应用不会把任何数据发到外部。

## 代码结构（速查）

| 文件 | 作用 |
| --- | --- |
| `SysMonBar/SysMonBarApp.swift` | 全部应用代码（SwiftUI + AppKit），单文件 |
| `SysMonBar/Assets.xcassets` | 应用图标源 |
| `build.sh` | Release 构建 + 注入图标 + 打 zip |
| `docs/adr/` | 架构决策记录 |

AI 额度模块以 `ProviderQuota` 协议为核心：每个厂商（DeepSeek、MiniMax）是实现该协议的 `ObservableObject`；`QuotaCoordinator` 聚合；`MenuContentView` 渲染面板。再接入一家厂商，只需实现该协议。

## 许可证

MIT。