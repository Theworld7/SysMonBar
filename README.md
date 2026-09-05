# SysMonBar

A lightweight macOS menu-bar app that shows live **system metrics** (CPU, memory, disk, network) and **AI subscription quotas** (DeepSeek, MiniMax) in a single popover.

Lives in the menu bar. No Dock icon.

📖 **[简体中文](README.zh-CN.md)**

## Install

Download `SysMonBar-v<version>.zip` from the [latest release](../../releases/latest), unzip, and drag `SysMonBar.app` into `/Applications`.

**First launch only:** macOS will block the app ("from an unidentified developer"). Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to SysMonBar.

## Features

### System metrics
- **CPU** — live usage % with color (green / orange / red as load climbs)
- **Memory** — used / total GB
- **Disk** — used % of the boot volume
- **Network** — up / down KB/s plus a 60-second smoothed sparkline (animated)

### AI subscription quotas
- **DeepSeek** — remaining balance (CNY / USD) queried via `GET /user/balance`, with a low-balance warning threshold.
- **MiniMax** — 5-hour and weekly *used* percentages queried via `GET /v1/token_plan/remains`. The API returns the remaining percentage; the panel converts it to **remaining = 100 − used** for display. See [`docs/adr/0001`](docs/adr/0001-minimax-balance-semantics.md).
- Both providers are polled every 5 minutes in the background; the panel can be refreshed manually with a single button that fetches both at once.

### Panel
- Single **Refresh** button (fetches both DeepSeek and MiniMax in one go).
- **Configure** button opens a dedicated window (`AI Provider 配置`) where each provider is a row:
  - Left: provider name. Right: **Switch** toggle.
  - Turning a switch on reveals an API Key input field.
  - **Master switch**: when off, the provider row disappears from the popover, the status bar, and the Settings toggles for it are disabled. Stored API keys are preserved.
  - The popover's main balance text turns red when the configured **warning threshold** is crossed (DeepSeek `balance ≤ threshold`, MiniMax `balance ≥ threshold`).

### Status bar
- Items shown are configurable per-metric (CPU / memory / disk / DeepSeek / MiniMax) via **System Settings → SysMonBar → 设置**.
- When a provider's master switch is off, its status bar item is hidden.

## Build

```bash
./build.sh              # build + inject icon + create zip
./build.sh --no-zip     # build + inject icon only
```

Outputs `build/Build/Products/Release/SysMonBar.app` and `SysMonBar-v<version>.zip`.

Requires macOS and Xcode (the project sets `MACOSX_DEPLOYMENT_TARGET = 27.0`).

## Notes

- Ad-hoc signed only. Not for App Store or Homebrew Cask distribution.
- Sampling APIs work on macOS 13+.
- The CPU sampler depends on the undocumented `HOST_CPU_LOAD_INFO` layout on recent macOS; see comments in `SysMonBarApp.swift`.
- API keys are stored locally in a SQLite KV store under `~/Library/Application Support/`. Nothing leaves the machine except the read-only quota requests to the providers' official APIs.

## Architecture (quick map)

| File | Role |
| --- | --- |
| `SysMonBar/SysMonBarApp.swift` | All app code (SwiftUI + AppKit), single file |
| `SysMonBar/Assets.xcassets` | App icon source |
| `build.sh` | Release build + icon injection + zip |
| `docs/adr/` | Architecture decision records |

The provider quota system is built around a `ProviderQuota` protocol. Each provider (DeepSeek, MiniMax) is an `ObservableObject` conforming to it; `QuotaCoordinator` aggregates them; `MenuContentView` renders the popover. Adding a third provider is a matter of implementing the protocol.

## License

MIT.