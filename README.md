# Snap Recorder

<div align="center">
  <img src="assets/SnapRecorderIcon.svg" width="88" alt="Snap Recorder 图标">
  <p><strong>极简录屏，高清保存。</strong></p>
  <p>极简 · 高清 · 双模式 · 本地处理 · Universal 2</p>
  <p>
    <a href="https://github.com/shuyan-5200/snap-recorder/releases/latest"><strong>下载最新版</strong></a>
    ·
    <a href="#从源码构建">从源码构建</a>
  </p>
</div>

Snap Recorder 是一款面向 macOS 的极简高清录屏工具。选择浏览器或整个屏幕，打开需要的声音，录完即可自动保存。

<p align="center">
  <img src="docs/images/snap-recorder-main.png" width="840" alt="Snap Recorder 主界面：整个屏幕、电脑声音与人声均已开启">
</p>

## 特性

- **两种录制模式**：浏览器、整个屏幕。
- **声音选择**：电脑声音、人声分别控制。
- **三种导出方式**：完整视频、视频与人声分开、两种同时导出。
- **高清成片**：原生像素优先，最高 3840×2160；H.264 High Profile，合并人声时视频轨不二次编码。
- **小而本地**：v0.2.0 Universal App 约 2.2 MB，ZIP 约 1.4 MB；无账号、无统计、无网络请求。

选择来源后，Snap Recorder 会倒计时 3 秒并隐藏主界面。录制中可暂停、继续或结束，文件自动保存到“下载”。Snap Recorder 的窗口和控制条不会进入成片。

## 两种录制模式

| 模式 | 画面 |
| --- | --- |
| 浏览器 | 只录浏览器窗口，自动铺满画面并保留少量桌面背景。 |
| 整个屏幕 | 录制当前主屏幕，保持原始比例和原生像素。 |

浏览器不必最大化，只要没有最小化即可录制。

## 声音与导出

| 导出方式 | 得到的文件 |
| --- | --- |
| 不录人声 | 自动保存 1 个 MP4，没有额外步骤。 |
| 完整视频 | 画面 + 电脑声音（如有）+ 人声，合成 1 个 MP4。 |
| 视频和人声分开 | 视频 MP4 + 对齐时长的人声 M4A，方便继续剪辑。 |
| 两种都要 | 一次得到完整 MP4、视频 MP4 和人声 M4A，共 3 个文件。 |

人声文件使用 AAC-LC、48 kHz、192 kbps；完整视频的混合音频为 48 kHz、256 kbps。

## 安装

1. 从 [Releases](https://github.com/shuyan-5200/snap-recorder/releases/latest) 下载 ZIP 并解压。
2. 把 `Snap Recorder.app` 移入“应用程序”。
3. 首次启动时允许“屏幕与系统音频录制”；开启人声时再允许麦克风。

当前预编译 App 尚未经过 Apple 公证。首次启动如果被 macOS 拦截，请右键 `Snap Recorder.app` →“打开”；仍被拦截时，前往“系统设置”→“隐私与安全性”→“仍要打开”。

## 系统要求

- 基础录屏：macOS 14 或更高版本。
- 人声录制：macOS 15 或更高版本。
- 支持 Apple Silicon 与 Intel Mac；预编译 App 为 Universal 2。

## 从源码构建

Snap Recorder 使用 SwiftUI、AppKit、ScreenCaptureKit、Core Image 和 AVFoundation，不依赖第三方库。

```bash
git clone https://github.com/shuyan-5200/snap-recorder.git
cd snap-recorder
./scripts/build-app.sh
```

构建结果位于 `build/Snap Recorder.app`。运行自动自检：

```bash
.build/release/SnapRecorder --self-test
```

## 隐私与边界

所有录屏和声音都只在本机处理。Snap Recorder 不联网、不上传、不收集统计，也不包含第三方分析 SDK。详见 [隐私说明](PRIVACY.md)。

为了保持极简，当前不提供编辑器、剪辑、自动变焦、摄像头、区域录制、多显示器选择或云分享。DRM 受保护内容仍可能被 macOS 显示为黑屏。

实现细节与验证记录见 [技术说明](docs/technical-notes.md) 和 [验证清单](docs/verification.md)。欢迎阅读 [贡献指南](CONTRIBUTING.md) 后提交 Issue 或 Pull Request。

## License

[MIT License](LICENSE)
