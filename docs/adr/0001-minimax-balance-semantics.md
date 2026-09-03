# MiniMax `balance` 语义翻转为"已使用百分比"

`MiniMaxProvider.balance` 现在表示"已使用百分比"，由 `100 - current_interval_remaining_percent`（API 返回的"剩余百分比"）换算得到。阈值规则 `balance ≥ 阈值 → 红` 对应"高使用率 = 警告"语义自洽。

## Status
accepted (2026-09-03)，2026-09-03 修正：原 ADR 假设 API 字段是"已使用 %"，经用户对照官网数据证实 API 字段实际是"剩余 %"（如 API 返回 92、官网显示"已使用 7"，`100 - 92 = 8 ≈ 7` 吻合），需 `100 -` 换算。

## Considered Options

- A. `balance` 直接表示 API 字段（"剩余 %"），阈值规则与 DeepSeek 对齐（`≤ 阈值 → 红`）—— 简单但与用户要求的 `≥ 阈值 → 红` 冲突。
- B. `balance = 100 - API 字段` 得"已使用 %"（已选）—— 阈值规则 `≥ 阈值 → 红` 自洽，状态栏 / segments / `summaryColor` 三处都按"已使用"方向表达。
- C. 保留 `balance = 剩余 %`，新增独立 `usedBalance` 供阈值判断 —— 三处都要分别选字段，重复维护一份。

## Consequences

- 状态栏数字显示"已使用%"（如 87%），与官网"已使用"口径一致。
- `progressSegments` 标签从 "5h 剩余"/"周剩余" 翻成 "5h 使用"/"周使用"。
- segments 着色方向翻转：`>0.5` 由绿变红。
- `summaryColor` 三档阈值翻转方向：原 `>50 绿/>20 橙/其余红` 改为 `<50 绿/<80 橙/其余红`。
- 解码字段 `currentIntervalRemainingPercent` 的注释从"接口实为已用额度"纠正为"API 字段名准确，返回的是剩余%"。
- 与官网的 1% 量级偏差：API 字段以 `Int` 解码（截断），官网显示通常 floor 截断到整数；如需消除需改 `Double` 解码，属独立问题。
