# 技术说明

## 核心链路

画面与电脑声音：

`SCStream → Core Image → AVAssetWriter → MP4`

可选人声：

`SCStream microphone output → 独立 AVAssetWriter → M4A`

没有使用 `SCRecordingOutput`，原因是它无法插入浏览器壁纸合成，也没有暂停 / 继续接口。

## 隐私隔离

- 浏览器：`SCContentFilter(desktopIndependentWindow:)`，采集源只包含一个窗口。
- 整屏：`SCContentFilter(display:excludingApplications:exceptingWindows:)`，排除 Snap Recorder 自己的进程。
- 倒计时和录制 HUD 的 `NSWindow.sharingType` 为 `.none`。
- 正式采集在倒计时面板隐藏后才启动。

## 暂停

ScreenCaptureKit 在暂停期间保持采集，但 writer 丢弃样本。继续时，画面、电脑声音和人声的时间戳统一扣除累计暂停时长，因此最终文件没有静止段或时间空洞。

正式时间轴以第一帧完整画面为起点。第一帧之前的声音样本不会写入；开启人声时还会等待首个人声样本，避免生成静默空轨。

## 人声与导出

- 人声使用 ScreenCaptureKit 的独立 microphone output，与画面共享系统时钟；该接口从 macOS 15 开始提供。
- 电脑声音和人声不能交错写入同一个实时 audio input，因此分别编码为独立临时文件。
- 合并导出通过 `AVAssetReaderAudioMixOutput` 混合电脑声音和人声，仅重新编码 AAC 音频。
- H.264 视频使用压缩样本 passthrough 重新封装；自动自检会比较合并前后的每个压缩视频样本哈希，确保画面没有再次编码。
- 分开导出保留原始 MP4，并将人声规范为 AAC-LC 48 kHz / 192 kbps；不足视频长度的头尾使用静音补齐，误差阈值为 40 毫秒。
- 导出页的两张卡可以多选。两项都选时，先在恢复目录生成完整视频与对齐人声，全部成功后再一次提交 3 个结果文件。
- 同一次导出的所有文件共用同一个重名后缀。任一步失败都回滚本次已提交的结果，并保留原始视频与人声以便重试。
- 合并音频为 AAC 48 kHz 双声道 / 256 kbps。电脑声音默认降至 78%，人声保持 100%，降低两路叠加时的削波风险。

## 浏览器画布

浏览器模式在开始录制时按所选窗口的 Retina 原始像素反推画布，最长边受 3840×2160 上限约束。浏览器内容在宽、高方向各留约 2.5% 壁纸边缘，内容框使用整数像素坐标，并禁止为填补舍入误差上采样，因此不会被拉伸、裁切或因半像素插值发软。ScreenCaptureKit 使用 `.best` 采集质量。MP4 画布在录制开始后固定；中途改变窗口长宽比时，仍以开始时的比例完成本次录制。

H.264 使用 High Profile、CABAC、Rec.709 与 60 fps，目标质量预算按输出像素约 24–68 Mbps，并明确让硬件编码器优先画质。静态屏幕内容的实际平均码率可能低于目标值。

## 恢复

录制先写到 `~/Library/Application Support/SnapRecorder/Recovery/`。封装成功后再移动到下载目录；需要选择人声导出方式时，临时视频和人声会保留到所选文件全部导出成功。失败时保留源文件并允许直接重试。

## 权限

屏幕、系统声音和麦克风权限由 macOS TCC 管理。人声默认关闭，只有用户主动开启时才请求麦克风权限。应用未启用沙盒，本地构建使用 ad-hoc 签名；公开分发建议使用 Developer ID 签名与公证。
