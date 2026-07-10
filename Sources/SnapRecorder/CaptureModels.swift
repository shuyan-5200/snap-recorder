import CoreGraphics
import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case browser
    case display

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: "浏览器窗口"
        case .display: "整个屏幕"
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

enum VoiceExportMode: CaseIterable, Hashable {
    case combined
    case separate
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

struct CaptureRequest {
    let mode: CaptureMode
    let browserWindowID: CGWindowID?
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let outputURL: URL
    let wallpaperURL: URL?
}

enum CaptureError: LocalizedError {
    case permissionRequired
    case noDisplay
    case noBrowserWindow
    case browserWindowUnavailable
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
    static let browserContentInsetFraction: CGFloat = 0.025

    struct BrowserLayout {
        let outputSize: CGSize
        let streamSize: CGSize
        let contentRect: CGRect
    }

    static func browserLayout(source: CGSize) -> BrowserLayout {
        guard source.width > 0, source.height > 0 else {
            return BrowserLayout(outputSize: .zero, streamSize: .zero, contentRect: .zero)
        }

        let contentFraction = 1 - 2 * browserContentInsetFraction
        let maximumContentSize = evenSize(
            width: maximumHighDefinitionOutputSize.width * contentFraction,
            height: maximumHighDefinitionOutputSize.height * contentFraction
        )
        let boundedSourceSize = fit(
            source: source,
            inside: maximumContentSize,
            allowUpscale: false
        )
        let outputSize = evenCeilingSize(
            width: boundedSourceSize.width / contentFraction,
            height: boundedSourceSize.height / contentFraction
        )
        let contentRect = browserContentRect(in: outputSize)
        let streamSize = fit(
            source: source,
            inside: contentRect.size,
            allowUpscale: false
        )
        return BrowserLayout(
            outputSize: outputSize,
            streamSize: streamSize,
            contentRect: contentRect
        )
    }

    static func browserContentRect(in outputSize: CGSize) -> CGRect {
        let contentFraction = 1 - 2 * browserContentInsetFraction
        let contentSize = evenSize(
            width: outputSize.width * contentFraction,
            height: outputSize.height * contentFraction
        )
        return CGRect(
            x: (outputSize.width - contentSize.width) / 2,
            y: (outputSize.height - contentSize.height) / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    static func evenSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: even(width), height: even(height))
    }

    static func evenCeilingSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: evenCeiling(width), height: evenCeiling(height))
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

    private static func evenCeiling(_ value: CGFloat) -> CGFloat {
        let integer = max(2, Int(value.rounded(.up)))
        return CGFloat(integer + integer % 2)
    }
}

enum RecordingQuality {
    static func videoBitrate(for outputSize: CGSize) -> Int {
        let pixelCount = Int(outputSize.width * outputSize.height)
        return max(24_000_000, min(68_000_000, pixelCount * 8))
    }
}
