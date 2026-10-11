import AVFoundation
import CoreGraphics
import Foundation

struct RecordingExportInfo {
    let duration: Double
    let size: CGSize
    let sourceBytes: Int64
    let hasSystemAudio: Bool
    let sourceVideoBitrate: Double
    let sourceFrameRate: Double
    let hasMicrophone: Bool
    var availableTracks: Set<RecordingTrack> {
        var tracks: Set<RecordingTrack> = [.video]
        if hasSystemAudio { tracks.insert(.systemAudio) }
        if hasMicrophone { tracks.insert(.voice) }
        return tracks
    }
}

struct VideoExportPlan {
    let size: CGSize
    let frameRate: Int
    let videoBitrate: Int
    let audioBitrate: Int
    let byteLimit: Int64?
    var preservesSource = false

    var estimatedBytesPerSecond: Double {
        Double(videoBitrate + audioBitrate) / 8 * 1.02
    }
}

enum ExportPlanning {
    static let frameRate = 30
    static let maximumCustomMegabytes = 100_000.0

    static func estimatedByteCeiling(for plan: VideoExportPlan, duration: Double) -> Int64 {
        Int64(plan.estimatedBytesPerSecond * duration * 1.06 + 16_384)
    }

    static func customSizeRecommendation(
        sourceSize: CGSize, duration: Double, hasSystemAudio: Bool,
        sourceVideoBitrate: Double?, sourceBytes: Int64,
        includesCombinedVoice: Bool
    ) throws -> (minimum: Double, suggestedMaximum: Double) {
        let tiny = try plan(sourceSize: sourceSize, duration: duration, preset: .tiny,
                            hasSystemAudio: hasSystemAudio, sourceVideoBitrate: sourceVideoBitrate,
                            includesCombinedVoice: includesCombinedVoice)
        // Match the actual "极小" export ceiling, then round up to a tenth of an MB.
        let minimum = max(0.1, ceil(Double(estimatedByteCeiling(for: tiny, duration: duration)) / 100_000) / 10)
        guard minimum <= maximumCustomMegabytes else {
            throw CaptureError.couldNotFinishWriter("这段录制的“极小”档已超过可设置的大小上限。")
        }
        let voiceBytes = includesCombinedVoice && !hasSystemAudio
            ? Double(RecordingQualityPreset.custom.audioBitrate) / 8 * duration : 0
        let sourceEstimate = ceil((Double(sourceBytes) + voiceBytes + 16_384) / 100_000) / 10
        return (minimum, min(maximumCustomMegabytes, max(minimum, sourceEstimate)))
    }

    static func plan(
        sourceSize: CGSize,
        duration: Double,
        preset: RecordingQualityPreset,
        customMegabytes: Double? = nil,
        hasSystemAudio: Bool,
        sourceVideoBitrate: Double? = nil,
        sourceFrameRate: Double? = nil,
        sourceBytes: Int64? = nil,
        includesCombinedVoice: Bool = false,
        bitrateScale: Double = 1,
        resolutionScale: Double = 1
    ) throws -> VideoExportPlan {
        guard duration.isFinite, duration > 0,
              sourceSize.width > 0, sourceSize.height > 0 else {
            throw CaptureError.couldNotFinishWriter("录制时长或画面尺寸无效。")
        }
        let hasAudio = hasSystemAudio || includesCombinedVoice
        let audioRate = hasAudio ? preset.audioBitrate : 0
        let nativeBitrate = maximumVideoBitrate(for: sourceSize)
        var bounds: CGSize
        var bitrate: Int
        var limit: Int64?
        switch preset {
        case .maximum, .balanced, .compact, .tiny:
            let scale = preset.resolutionScale ?? 1
            bounds = relativeSize(sourceSize, scale: scale)
            bitrate = max(80_000, Int(Double(nativeBitrate) * preset.videoBitrateFraction))
        case .custom:
            let recommendation = try customSizeRecommendation(
                sourceSize: sourceSize, duration: duration, hasSystemAudio: hasSystemAudio,
                sourceVideoBitrate: sourceVideoBitrate, sourceBytes: sourceBytes ?? 0,
                includesCombinedVoice: includesCombinedVoice
            )
            let minimum = recommendation.minimum
            guard let mb = customMegabytes, mb.isFinite,
                  mb >= minimum, mb <= maximumCustomMegabytes else {
                throw CaptureError.couldNotFinishWriter(
                    "视频上限请输入 \(String(format: "%.1f", minimum))–100000 MB，不应低于“极小”档的体积预算。"
                )
            }
            limit = Int64(mb * 1_000_000)
            let mixReserve = includesCombinedVoice
                ? (hasSystemAudio ? 16_384 : Double(audioRate) / 8 * duration + 16_384) : 0
            if let sourceBytes, let sourceFrameRate,
               sourceFrameRate > 0, sourceFrameRate <= Double(frameRate) + 0.001,
               Double(sourceBytes) + mixReserve <= Double(limit!),
               bitrateScale == 1, resolutionScale == 1 {
                return VideoExportPlan(
                    size: sourceSize, frameRate: frameRate,
                    videoBitrate: Int(sourceVideoBitrate ?? 1_000_000),
                    audioBitrate: audioRate, byteLimit: limit, preservesSource: true
                )
            }
            // Leave room for AAC, MP4 tables and short-clip overhead, then verify the file.
            let budget = (Double(limit!) * 0.94 - 16_384) * 8 / duration - Double(audioRate)
            guard budget >= 80_000 else {
                throw CaptureError.couldNotFinishWriter("这个体积不足以保存完整录制，请提高大小上限。")
            }
            bitrate = min(32_000_000, Int(budget))
            // Pixel count and bitrate both scale with area. Derive a continuous
            // dimension ratio from the available bitrate instead of snapping
            // arbitrary recordings to fixed 1080p/720p/480p canvases.
            let scale = min(1, max(0.125, sqrt(Double(bitrate) / Double(nativeBitrate))))
            bounds = relativeSize(sourceSize, scale: scale)
        }
        let size = CaptureSizing.fit(source: sourceSize, inside: bounds, allowUpscale: false)
        if let sourceVideoBitrate, sourceVideoBitrate.isFinite, sourceVideoBitrate > 0 {
            bitrate = min(
                bitrate,
                max(80_000, Int(sourceVideoBitrate * preset.videoBitrateFraction))
            )
        }
        return VideoExportPlan(
            size: CaptureSizing.evenSize(width: size.width * resolutionScale, height: size.height * resolutionScale),
            frameRate: frameRate,
            videoBitrate: max(80_000, Int(Double(bitrate) * bitrateScale)),
            audioBitrate: audioRate,
            byteLimit: limit
        )
    }

    private static func maximumVideoBitrate(for sourceSize: CGSize) -> Int {
        max(1_000_000, min(32_000_000, Int(sourceSize.width * sourceSize.height * 5.8)))
    }

    private static func relativeSize(_ sourceSize: CGSize, scale: CGFloat) -> CGSize {
        CaptureSizing.evenSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
    }

    /// Window titles may contain path separators, control characters or more
    /// bytes than a legal export name. Preserve readable text, not a path.
    static func recordingName(windowTitle: String?, fallback: String) -> String {
        guard let windowTitle else { return fallback }
        let cleaned = windowTitle.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" { return " - " }
            if isForbiddenNameControl(scalar) { return " " }
            return String(scalar)
        }.joined()
        var name = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var limited = ""
        for character in name {
            guard limited.utf8.count + String(character).utf8.count <= 180 else { break }
            limited.append(character)
        }
        return (try? validatedName(limited, fallback: fallback)) ?? fallback
    }

    static func validatedName(_ input: String, fallback: String) throws -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".mp4") { name.removeLast(4) }
        if name.isEmpty { name = fallback }
        guard name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !isForbiddenNameControl($0) }),
              name.utf8.count <= 180 else {
            throw CaptureError.couldNotFinishWriter("文件名不能以句点开头、包含 / 或 :，或超过 180 字节。")
        }
        return name
    }

    private static func isForbiddenNameControl(_ scalar: Unicode.Scalar) -> Bool {
        // Keep the joiner used by compound emoji; other controls stay invalid.
        scalar.value != 0x200D && CharacterSet.controlCharacters.contains(scalar)
    }

    static func fileBytes(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func sizeText(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", bytes / 1_000_000_000) }
        return String(format: "%.1f MB", bytes / 1_000_000)
    }
}
