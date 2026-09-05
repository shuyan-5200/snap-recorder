<div align="center">
  <img src="assets/SnapRecorderIcon.svg" width="96" alt="Snap Recorder 图标">
  <h1>Snap Recorder</h1>
  <p><strong>极简录屏，高清保存。</strong></p>
  <h2>
    <a href="https://github.com/shuyan-5200/snap-recorder">查看源码</a>
    &nbsp;&nbsp;&nbsp;
    <a href="https://github.com/shuyan-5200/snap-recorder/releases/latest">下载已发布版本</a>
  </h2>
  <p>面向 macOS 的轻量录屏工具：浏览器、整个屏幕或自定义区域，本地处理，录完选择画质并保存。</p>
  <p><sub>A tiny, local-first macOS screen recorder for browser windows, the full display, and custom regions.</sub></p>
  <p>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/shuyan-5200/snap-recorder?style=flat-square" alt="MIT License"></a>
    <img src="https://img.shields.io/badge/macOS-14%2B-111111?style=flat-square&amp;logo=apple" alt="macOS 14 或更高版本">
  </p>
</div>

Snap Recorder 把录屏缩短成一条短路径：**选择来源 → 3 秒倒计时 → 录制 → 选择画质 → 保存到“下载”**。没有账号，没有云同步，也不需要先学习一个编辑器。

当前公开版本为 **0.4.0（build 11）**，在 0.3.1 的浏览器、整屏、局部录像基础上加入可选摄像头画中画与苹果原生“自然修饰”，并修复强度滑杆拖动时误移动窗口的问题。以下录屏模式截图来自 0.3.1；各构建的安装与真实设备验收状态见[验证清单](docs/verification.md)，旧构建的结果不代表当前构建已通过验收。

| 录制模式 | 导出画质 | 网络请求 | Universal App |
| --- | --- | --- | --- |
| 浏览器窗口 / 整个屏幕 / 局部录像 | 最高画质 / 清晰小体积 | 0 | Apple Silicon + Intel |

## 1. 窗口模式

只录浏览器窗口，按窗口原始比例完整铺满成片，不添加桌面背景。

<p align="center">
  <img src="assets/screenshots/actual-browser-window-mode.png" width="840" alt="Snap Recorder 浏览器窗口模式：选择一个浏览器窗口，并设置电脑声音、人声与鼠标">
  <br>
  <sub>窗口模式：从列表选择要录制的浏览器窗口</sub>
</p>

打开要录制的浏览器窗口，在“录制来源”中选择“浏览器窗口”，再从列表中选中目标窗口。浏览器不必最大化，只要没有最小化即可录制；找不到窗口时，点右侧刷新按钮。

## 2. 整屏模式

录制当前主屏幕，保持原始比例和原生像素。适合需要在多个应用之间切换的演示。

<p align="center">
  <img src="assets/screenshots/actual-full-screen-mode.png" width="840" alt="Snap Recorder 整个屏幕模式：当前主屏幕已选中，并显示电脑声音、人声与鼠标设置">
  <br>
  <sub>整屏模式：录制当前主屏幕</sub>
</p>

这个模式不需要选择窗口或调整画面比例。Snap Recorder 的主窗口、倒计时与录制控制条不会进入成片。

## 3. 局部模式

在当前主屏幕上划定一个区域，只录虚线框内的内容。

<p align="center">
  <img src="assets/screenshots/actual-region-recording-controls.png" width="840" alt="Snap Recorder 局部录像设置：七种画面比例、录制框边角、柔和圆角暗角、聚焦蒙版、声音与鼠标选项">
  <br>
  <sub>局部模式：选择比例，再拖动虚线框决定成片范围</sub>
</p>

固定比例包括 `16:9`、`9:16`、`4:3`、`3:4`、`21:9` 和 `1:1`，拖动时始终保持所选比例；选择“自定义”后，宽高可以自由调整。

录制框默认圆角，也可以改为方角。“柔和圆角暗角”会在成片四角加入轻微渐变，让边缘更自然；虚线框本身不会录进视频。

选择固定比例后，还可以打开“聚焦蒙版”。蒙版内部保持原色和原亮度，外部转为单色并压暗 50%；小蒙版可以移动、缩放，也可以选择方角或圆角，默认圆角，边缘带一圈灰色细线。

<p align="center">
  <img src="assets/screenshots/actual-region-focus-mask.jpeg" width="840" alt="局部录像的圆角聚焦蒙版：内部高亮，外部转为单色并压暗百分之五十">
  <br>
  <sub>外层虚线框决定成片范围，小蒙版保留原色</sub>
</p>

调整完成后按 `⌘E` 锁定选区。框线会保留为浮层，但框线下面的界面已经可以操作；再次按 `⌘E`，即可继续调整。

## 4. 全局设定

三个录制模式共用以下设置：

| 选项 | 说明 |
| --- | --- |
| 电脑声音 | 录制应用与网页声音，不包含麦克风。 |
| 人声（麦克风） | 默认关闭；开启后录制系统默认麦克风，并可在结束时选择合并或分轨导出。 |
| 摄像头 | 默认关闭，与人声独立；开启后显示本地人像预览，录屏成片中带上摄像头画面。 |
| 录制鼠标 | 默认开启；成片中的鼠标会变成带光晕的圆形光点，点击时出现扩散效果。关闭后不显示鼠标。 |

### 摄像头画中画

开启“摄像头”并完成 macOS 授权后，可在录制前确认人像预览。默认在成片右下角显示圆角方形人像，镜像开启；主窗口内的轻设置提供圆角方形 / 圆形、三档大小、四角位置和镜像开关。位置使用 2×2 卡片，整张卡片均可点击。三种录屏模式都适用，画中画按成片尺寸定位；摄像头不会自动开启麦克风。

“自然修饰”提供 **原图 / 自然 / 柔和** 三档，默认原图，不再使用连续强度滑杆。自然档轻柔肤质，柔和档加强肤质柔化；两档都不瘦脸、不美妆、不改变五官形状。它使用免费的苹果原生 Core Image 与 Vision，仅在本机内存中检测正脸区域并处理摄像头画面，不处理桌面内容。检测不到可靠正脸时保留原图；画面本身越干净，柔化差别越小。预览和成片使用同一份处理后的画面。

摄像头画面在录制时直接合入视频，结束后仍然只需选择画质，以及已开启人声时的人声导出方式。预览浮窗和录制控制不会被重复录入。摄像头不单独导出；自然修饰只定位人脸区域，不识别身份，也不保存人脸模型、特征向量或检测标记。

关闭摄像头开关、停止录制，或在未录制时关闭主窗口，都会释放摄像头。设备未连接、被占用或意外断开时会给出说明；录制中断开会停止录制，并尽力保留已录内容。

### 快捷键

| 快捷键 | 作用 |
| --- | --- |
| `⌘R` | 开始录制。窗口与整屏模式需要主窗口处于前台；局部模式锁定后可全局使用。 |
| `⌘E` | 只用于局部模式，在“调整选区”和“点击穿透”之间切换。 |
| `Esc` | 录制中或暂停时，全局结束录制。 |

`⌘E` 在窗口和整屏模式下不起作用。`Esc` 只在录制中接管，不会长期占用。

## 5. 导出设置

结束录制后可选择“最高画质”或“清晰小体积”。最高画质直接保留录制原片；小体积档保持相同分辨率，使用约 1/3 的视频目标码率重新压缩，并开启更高压缩效率，优先保住网页文字和界面细节。实际文件大小仍会随画面变化与声音内容浮动。

<p align="center">
  <img src="assets/screenshots/actual-export-quality.png" width="840" alt="Snap Recorder 录制结束后的双画质导出选择：最高画质与清晰小体积">
  <br>
  <sub>同一段录屏，可选择保留原片质量，或保持分辨率并把目标体积压缩到约 1/3</sub>
</p>

| 导出方式 | 得到的文件 |
| --- | --- |
| 不录人声 | 选择画质后保存 1 个 MP4。 |
| 完整视频 | 画面 + 电脑声音（如有）+ 人声，合成 1 个 MP4。 |
| 视频和人声分开 | 视频 MP4 + 对齐时长的人声 M4A，方便继续剪辑。 |
| 两种都要 | 一次得到完整 MP4、视频 MP4 和人声 M4A，共 3 个文件。 |

人声文件使用 AAC-LC、48 kHz、192 kbps；完整视频的混合音频为 48 kHz、256 kbps。

## 安装

1. 下载或构建 `Snap Recorder.app`。
2. 把 `Snap Recorder.app` 移入“应用程序”。
3. 首次启动时允许“屏幕与系统音频录制”；开启人声时再允许麦克风，开启摄像头时再允许摄像头。

当前本地构建的 App 尚未经过 Apple 公证。首次启动如果被 macOS 拦截，请右键 `Snap Recorder.app` →“打开”；仍被拦截时，前往“系统设置”→“隐私与安全性”→“仍要打开”。

<details>
<summary><strong>屏幕录制权限反复出现</strong></summary>

如果以前运行过旧签名或其他位置的副本：

1. 完全退出 Snap Recorder。
2. 只保留 `/Applications/Snap Recorder.app`。
3. 在“系统设置”→“隐私与安全性”→“屏幕与系统音频录制”中移除旧条目。
4. 条目仍异常时执行：

   ```bash
   tccutil reset ScreenCapture io.github.shuyan-5200.SnapRecorder
   ```

5. 重新打开“应用程序”中的 Snap Recorder，授权后按提示退出并重启。

构建脚本使用稳定的本地 App 身份。完成一次旧版迁移后，不需要每次重新授权。

</details>

## 系统要求

- 基础录屏：macOS 14 或更高版本。
- 人声录制：macOS 15 或更高版本。
- 支持 Apple Silicon 与 Intel Mac；构建结果为 Universal 2 App。

## 从源码构建

Snap Recorder 使用 SwiftUI、AppKit、ScreenCaptureKit、Core Image、Vision 和 AVFoundation，不依赖第三方库或付费美颜组件。

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

所有录屏、摄像头画面和声音都只在本机处理。Snap Recorder 不联网、不上传、不收集统计，也不包含第三方分析 SDK。详见 [隐私说明](PRIVACY.md)。

为了保持极简，当前不提供编辑器、剪辑、自动变焦、摄像头分轨、多显示器选择或云分享。DRM 受保护内容仍可能被 macOS 显示为黑屏。

实现细节与验证记录见 [技术说明](docs/technical-notes.md) 和 [验证清单](docs/verification.md)。欢迎阅读 [贡献指南](CONTRIBUTING.md) 后提交 Issue 或 Pull Request。

## License

本项目使用 [MIT License](LICENSE)。感谢 [kennanzhou](https://github.com/kennanzhou/snap-recorder-Partial-recording) 贡献局部录像、聚焦蒙版与鼠标效果等改进。
