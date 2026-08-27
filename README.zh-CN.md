# SysMonBar

一个轻量的 macOS 菜单栏应用，实时显示 CPU / 内存 / 磁盘 / 网络，并带 60 秒动态折线图。

![screenshot placeholder](screenshot.png)

📖 **[English](README.md)**

## 安装

从 [最新发布](../../releases/latest) 下载 `SysMonBar-v<版本>.zip`，解压，把 `SysMonBar.app` 拖到 `/Applications`。

首次启动：macOS 会拦截（"来自身份不明的开发者"）。打开 **系统设置 → 隐私与安全性**，向下滚动，点 SysMonBar 旁边的 **仍要打开**。

不占 Dock 图标。

## 功能

- **CPU** —— 实时百分比，带颜色（绿 / 橙 / 红 随负载升高）
- **内存** —— 已用 / 总量 GB
- **磁盘** —— 已用百分比（启动盘）
- **网络** —— 上下行 KB/s + 60 秒折线图（平滑曲线 + 动画）

## 构建

```bash
./build.sh
```

产物：`build/Build/Products/Release/SysMonBar.app` 和 `SysMonBar-v<版本>.zip`。只构建不要 zip：`./build.sh --no-zip`。

需要 macOS + Xcode 26（App Store 版或 beta 版均可）。

## 注意事项

- 仅 ad-hoc 本地签名，未公证。不可发布到 App Store 或 Homebrew Cask。
- 采样 API 适用于 macOS 13+。
- CPU 采样依赖 macOS 26+ 上 `HOST_CPU_LOAD_INFO` 的未文档化布局，详见 `SysMonBarApp.swift` 注释。

## 许可证

MIT。