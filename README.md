# SysMonBar

A tiny macOS menubar app showing live CPU / memory / disk / network with a 60s sparkline.

![screenshot placeholder](screenshot.png)

📖 **[简体中文](README.zh-CN.md)**

## Install

Download `SysMonBar-v<version>.zip` from the [latest release](../../releases/latest), unzip, and drag `SysMonBar.app` into `/Applications`.

First launch only: macOS will block the app ("from an unidentified developer"). Go to **System Settings → Privacy & Security** and click **Open Anyway** next to SysMonBar.

No Dock icon. Lives in the menu bar.

## Features

- **CPU** — live % with color (green / orange / red as load climbs)
- **Memory** — used / total GB
- **Disk** — used % (boot volume)
- **Network** — up/down KB/s + 60s sparkline (smooth curve, animated)

## Build

```bash
./build.sh
```

Outputs `build/Build/Products/Release/SysMonBar.app` and `SysMonBar-v<version>.zip`. Skip the zip with `./build.sh --no-zip`.

Requires macOS + Xcode 26 (App Store or beta).

## Notes

- Ad-hoc signed only. Not for App Store or Homebrew Cask distribution.
- Sampling APIs work on macOS 13+.
- CPU sampling depends on undocumented `HOST_CPU_LOAD_INFO` layout on macOS 26+; see comments in `SysMonBarApp.swift`.

## License

MIT.