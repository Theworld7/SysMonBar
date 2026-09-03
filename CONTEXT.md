# SysMonBar

macOS 状态栏小工具，监听本机系统资源（CPU / 内存 / 磁盘 / 网络）以及 AI 订阅额度（DeepSeek / MiniMax）。

## Language

**Provider**:
一个外部 AI 服务的接入方，实现 `ProviderQuota` 协议，由 `QuotaCoordinator` 聚合并对外暴露。
_Avoid_: vendor、service、渠道

**余额 (Balance)**:
Provider 当前展示的余额数值，字段统一为 `balance: Decimal?`，但语义因 provider 而异（见下两条）。
_Avoid_: amount、quota、credit

**剩余金额 (Remaining Amount)**:
DeepSeek `balance` 的语义：可用的现金余额（CNY / USD），由 `DeepSeekBalance.totalBalance` 解出。**低余额 = 警告**。
_Avoid_: 充值余额、总余额（这些是部分视角）

**已使用百分比 (Used Percentage)**:
MiniMax `balance` 的语义：当前窗口（如 5h）已消耗的额度百分比 0–100，由 API 字段 `current_interval_remaining_percent` 通过 `100 - 字段值` 换算得到（API 返回的是剩余%，见 `docs/adr/0001`）。**高使用率 = 警告**。
_Avoid_: 已用%、剩余%（这个 provider 的字段是剩余%，`balance` 是派生量）

**预警阈值 (Warning Threshold)**:
用户在 `AIProviderConfigView` 配置的余额告警边界，命中时把弹窗中 provider 主文本染红。规则因 provider 语义而异：DeepSeek `balance ≤ 阈值 → 红`，MiniMax `balance ≥ 阈值 → 红`。持久化键 `ai.{provider}_warning_threshold`，默认 DeepSeek=5 CNY / MiniMax=80。仅作用于弹窗 `summaryColor` 文本，**不影响状态栏、progressSegments**。

**summaryColor**:
Provider 弹窗主文本的三档颜色（绿/橙/红）。绿/橙边界由 provider 硬编码（DeepSeek 100 / MiniMax 50），橙/红边界由"预警阈值"决定。

**progressSegments**:
Provider 自带的多条进度条，目前只有 MiniMax 使用（5h / 周限额两条）。`percent` 为 0–1 的小数，标签 "5h 使用"/"周使用"。

**总控开关 (Master Switch)**:
控制整个 provider 是否参与轮询与展示：`deepSeekEnabled` / `miniMaxEnabled`。关闭后弹窗里不出现该行，状态栏对应 toggle 强制 disabled。
_Avoid_: 总开关、大开关、master

**状态栏显隐开关 (Status Bar Toggle)**:
仅控制状态栏 label 是否包含该 provider 余额：`showDeepSeek` / `showMiniMax`。总控关闭时该 toggle 被 disable 但本身保留。