import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

enum CaptureMode: String, CaseIterable, Identifiable {
    case browser
    case display
    case region

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: "浏览器窗口"
        case .display: "整个屏幕"
        case .region: "局部录像"
        }
    }
}

enum CaptureAspectRatio: String, CaseIterable, Identifiable {
    case widescreen
    case portrait
    case standard
    case portraitStandard
    case ultrawide
    case square
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .widescreen: "16:9"
        case .portrait: "9:16"
        case .standard: "4:3"
        case .portraitStandard: "3:4"
        case .ultrawide: "21:9"
        case .square: "1:1"
        case .custom: "自定义"
        }
    }

    var fixedValue: CGFloat? {
        switch self {
        case .widescreen: 16 / 9
        case .portrait: 9 / 16
        case .standard: 4 / 3
        case .portraitStandard: 3 / 4
        case .ultrawide: 21 / 9
        case .square: 1
        case .custom: nil
        }
    }
}

enum RecordingPhase: Equatable {
    case idle
    case countdown
    case recording
    case paused
    case preparingExport
    case choosingExport
    case exporting
    case finished
    case failed

    var isCapturing: Bool {
        self == .recording || self == .paused
    }
}

enum RecordingTrack: String, CaseIterable, Hashable, Identifiable {
    case video, systemAudio, voice
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: "视频"
        case .systemAudio: "电脑声音"
        case .voice: "人声"
        }
    }
}

enum ExportArrangement: String, CaseIterable, Identifiable {
    case merged, separate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .merged: "合并"
        case .separate: "分轨"
        }
    }
}

enum ExportFileKind {
    case mergedVideo, video, systemAudio, voice, mixedAudio
}

struct RecordingExportSelection {
    var tracks: Set<RecordingTrack>
    var arrangement: ExportArrangement
    var includesVideo: Bool { tracks.contains(.video) }
    var includesSystemInVideo: Bool {
        includesVideo && tracks.contains(.systemAudio) && arrangement != .separate
    }
    var includesVoiceInVideo: Bool {
        includesVideo && tracks.contains(.voice) && arrangement == .merged
    }
    var files: [ExportFileKind] {
        if arrangement == .merged {
            if includesVideo { return [.mergedVideo] }
            if tracks.contains(.systemAudio), tracks.contains(.voice) { return [.mixedAudio] }
        }
        return RecordingTrack.allCases.filter { tracks.contains($0) }.map {
            switch $0 {
            case .video: .video
            case .systemAudio: .systemAudio
            case .voice: .voice
            }
        }
    }

    func validate(available: Set<RecordingTrack>) throws {
        guard !tracks.isEmpty, tracks.isSubset(of: available) else {
            throw CaptureError.couldNotFinishWriter("请选择已录制的内容。")
        }
    }
}

enum RecordingQualityPreset: String, CaseIterable, Identifiable {
    case maximum, balanced, compact, tiny, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maximum: "高清"
        case .balanced: "日常"
        case .compact: "小巧"
        case .tiny: "极小"
        case .custom: "自定义"
        }
    }

    var detail: String {
        switch self {
        case .maximum: "原始尺寸 · 30 帧"
        case .balanced: "最高 1080p · 30 帧"
        case .compact: "最高 720p · 30 帧"
        case .tiny: "最高 480p · 30 帧"
        case .custom: "按大小上限适配尺寸 · 30 帧"
        }
    }

    var audioBitrate: Int {
        switch self {
        case .maximum: 192_000
        case .balanced: 128_000
        case .compact, .custom: 96_000
        case .tiny: 64_000
        }
    }
}

struct RecordingResult {
    let urls: [URL]

    var primaryURL: URL? { urls.first }
}

enum CaptureStopOutcome {
    case exported(RecordingResult)
    case awaitingExportChoice
}

struct BrowserWindowInfo: Identifiable, Equatable {
    let id: CGWindowID
    let processID: pid_t
    let applicationName: String
    let bundleIdentifier: String
    let title: String
    let isOnScreen: Bool
    let size: CGSize

    var displayTitle: String {
        title.isEmpty ? "未命名窗口" : title
    }
}

struct CaptureRegion: Equatable {
    let displayID: CGDirectDisplayID
    /// ScreenCaptureKit display-local coordinates in points, with a top-left origin.
    let sourceRect: CGRect
}

enum FocusMaskCornerStyle: String, CaseIterable, Identifiable {
    case square
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .square: "方角"
        case .rounded: "圆角"
        }
    }
}

struct CaptureFocusMask: Equatable {
    /// Unit coordinates inside the selected capture region, with a bottom-left origin.
    let normalizedRect: CGRect
    let cornerStyle: FocusMaskCornerStyle
}

struct MouseClickEffect: Equatable {
    /// Unit coordinates inside the captured source, with a top-left origin.
    let normalizedPosition: CGPoint
    /// A value from 0 (click began) through 1 (ripple finished).
    let progress: CGFloat
}

struct MouseEffectSnapshot: Equatable {
    /// Unit coordinates inside the captured source, with a top-left origin.
    let normalizedCursorPosition: CGPoint?
    let clickEffect: MouseClickEffect?
}

struct CaptureRequest {
    let mode: CaptureMode
    let browserWindowID: CGWindowID?
    let region: CaptureRegion?
    let focusMask: CaptureFocusMask?
    let captureCornerStyle: FocusMaskCornerStyle
    let appliesSoftCornerVignette: Bool
    let capturesMouseEffects: Bool
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let outputURL: URL
    var cameraOverlay: CameraOverlaySettings? = nil
}

enum CaptureError: LocalizedError {
    case permissionRequired
    case noDisplay
    case noBrowserWindow
    case browserWindowUnavailable
    case noCaptureRegion
    case captureRegionUnavailable
    case noVideoFrames
    case microphoneRequiresNewerSystem
    case microphonePermissionRequired
    case microphoneUnavailable
    case noMicrophoneSamples
    case insufficientDiskSpace
    case insufficientExportDiskSpace
    case couldNotStartWriter(String)
    case couldNotFinishWriter(String)
    case streamStopped(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "需要先允许屏幕录制权限。"
        case .noDisplay:
            "没有找到可录制的显示器。"
        case .noBrowserWindow:
            "请先打开一个浏览器窗口。"
        case .browserWindowUnavailable:
            "选中的浏览器窗口已经关闭或不可用。"
        case .noCaptureRegion:
            "请先在屏幕上调整好局部录制范围。"
        case .captureRegionUnavailable:
            "局部录制范围已不可用，请重新选择。"
        case .noVideoFrames:
            "没有收到可录制画面。录浏览器时请确认窗口没有最小化，然后重试。"
        case .microphoneRequiresNewerSystem:
            "人声录制需要 macOS 15 或更高版本。"
        case .microphonePermissionRequired:
            "需要先允许麦克风权限，才能录制人声。"
        case .microphoneUnavailable:
            "没有找到可用的麦克风，请检查系统输入设备。"
        case .noMicrophoneSamples:
            "没有收到麦克风声音，请检查系统默认麦克风后重试。"
        case .insufficientDiskSpace:
            "下载文件夹剩余空间不足 5 GB，请清理后再录制。"
        case .insufficientExportDiskSpace:
            "所选导出版本需要更多空间。请清理“下载”，或取消一种版本后重试。"
        case .couldNotStartWriter(let detail):
            "无法开始生成视频：\(detail)"
        case .couldNotFinishWriter(let detail):
            "视频保存失败：\(detail)"
        case .streamStopped(let detail):
            "录制意外停止：\(detail)"
        }
    }
}

enum CaptureSizing {
    static let maximumHighDefinitionOutputSize = CGSize(width: 3_840, height: 2_160)

    struct BrowserLayout {
        let outputSize: CGSize
        let streamSize: CGSize
        let contentRect: CGRect
    }

    static func browserLayout(source: CGSize) -> BrowserLayout {
        guard source.width > 0, source.height > 0 else {
            return BrowserLayout(outputSize: .zero, streamSize: .zero, contentRect: .zero)
        }

        let outputSize = fit(
            source: source,
            inside: maximumHighDefinitionOutputSize,
            allowUpscale: false
        )
        return BrowserLayout(
            outputSize: outputSize,
            streamSize: outputSize,
            contentRect: CGRect(origin: .zero, size: outputSize)
        )
    }

    static func regionOutputSize(source: CGSize) -> CGSize {
        fit(
            source: source,
            inside: maximumHighDefinitionOutputSize,
            allowUpscale: false
        )
    }

    static func evenSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: even(width), height: even(height))
    }

    static func fit(source: CGSize, inside bounds: CGSize, allowUpscale: Bool = true) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let resolvedScale = allowUpscale ? scale : min(scale, 1)
        return evenSize(
            width: source.width * resolvedScale,
            height: source.height * resolvedScale
        )
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        let integer = max(2, Int(value.rounded(.down)))
        return CGFloat(integer - integer % 2)
    }
}

enum RecordingQuality {
    // The capture master stays generous; exports always start from this master.
    static func videoBitrate(for outputSize: CGSize, preset: RecordingQualityPreset) -> Int {
        max(24_000_000, min(68_000_000, Int(outputSize.width * outputSize.height * 8)))
    }

    static func videoSettings(
        for outputSize: CGSize,
        preset: RecordingQualityPreset,
        prioritizesQuality: Bool
    ) -> [String: Any] {
        settings(size: outputSize, bitrate: videoBitrate(for: outputSize, preset: preset),
                 frameRate: ExportPlanning.frameRate, reordersFrames: false, prioritizesQuality: prioritizesQuality)
    }

    static func settings(
        size: CGSize, bitrate: Int, frameRate: Int,
        reordersFrames: Bool, prioritizesQuality: Bool, limitsDataRate: Bool = false
    ) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            AVVideoAllowFrameReorderingKey: reordersFrames,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC
        ]
        if prioritizesQuality {
            compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = false
        }
        if limitsDataRate {
            compression[kVTCompressionPropertyKey_DataRateLimits as String] = [Double(bitrate) / 8, 1.0]
        }
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
    }
}
