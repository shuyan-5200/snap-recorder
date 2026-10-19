# Snap Recorder

原生 macOS 录屏应用。支持窗口、整屏与局部录制，按需录入电脑声音、人声和摄像头画中画。视频与音频在本机处理，确认后保存到「下载」。

运行环境：macOS 14 或更新版本；人声录制需要 macOS 15 或更新版本。

## 构建与验证

安装 Xcode Command Line Tools 后执行，无需完整 Xcode 或第三方库：

```bash
swift build -c release
.build/release/SnapRecorder --self-test
./scripts/build-app.sh
```

构建结果为 `build/Snap Recorder.app`，包含 Apple Silicon 与 Intel 两种架构。打包直接使用 `app/SnapRecorderIcon.icns` 成品图标。

首次录制需要允许屏幕录制权限；麦克风与摄像头仅在开启对应功能时请求权限。

## 源码结构

- `Sources/SnapRecorder/`：应用界面、采集、合成、导出与自检。
- `app/`：应用配置与打包所需图标。
- `scripts/build-app.sh`：构建与签名。
- `.github/workflows/ci.yml`：自动构建与自检。

[贡献指南](CONTRIBUTING.md) · [隐私说明](PRIVACY.md) · [安全说明](SECURITY.md) · [版本下载](https://github.com/shuyan-5200/snap-recorder/releases)

MIT 许可，见 [LICENSE](LICENSE)。
