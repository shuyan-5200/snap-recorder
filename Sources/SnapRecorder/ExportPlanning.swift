import AVFoundation
import CoreGraphics
import Foundation

struct RecordingExportInfo {
    let duration: Double
    let size: CGSize
    let sourceBytes: Int64
    let hasSystemAudio: Bool
    let sourceVideoBitrate: Double
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
    static func plan(
        sourceSize: CGSize,
        duration: Double,
        preset: RecordingQualityPreset,
        customMegabytes: Double? = nil,
        hasSystemAudio: Bool,
        sourceVideoBitrate: Double? = nil,
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
        var bounds: CGSize
        var fps: Int
        var bitrate: Int
        var limit: Int64?
        switch preset {
        case .maximum:
            bounds = sourceSize
            fps = 60
            // Native pixels, with a much lower ceiling than the capture master.
            bitrate = max(1_000_000, min(32_000_000, Int(sourceSize.width * sourceSize.height * 5.8)))
        case .balanced:
            bounds = CGSize(width: 1_920, height: 1_080)
            fps = 30
            bitrate = 4_000_000
        case .compact:
            bounds = CGSize(width: 1_280, height: 720)
            fps = 30
            bitrate = 1_200_000
        case .tiny:
            bounds = CGSize(width: 854, height: 480)
            fps = 24
            bitrate = 400_000
        case .custom:
            guard let mb = customMegabytes, mb.isFinite, mb >= 0.1, mb <= 100_000 else {
                throw CaptureError.couldNotFinishWriter("请输入 0.1–100000 MB 之间的视频大小。")
            }
            limit = Int64(mb * 1_000_000)
            let mixReserve = includesCombinedVoice
                ? (hasSystemAudio ? 16_384 : Double(audioRate) / 8 * duration + 16_384) : 0
            if let sourceBytes, Double(sourceBytes) + mixReserve <= Double(limit!),
               bitrateScale == 1, resolutionScale == 1 {
                return VideoExportPlan(
                    size: sourceSize, frameRate: 60,
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
            let effectiveRate = Double(bitrate)
            if effectiveRate >= 10_000_000 {
                bounds = sourceSize
                fps = 60
            } else if effectiveRate >= 2_400_000 {
                bounds = CGSize(width: 1_920, height: 1_080)
                fps = 30
            } else if effectiveRate >= 800_000 {
                bounds = CGSize(width: 1_280, height: 720)
                fps = 30
            } else if effectiveRate >= 250_000 {
                bounds = CGSize(width: 854, height: 480)
                fps = 24
            } else if effectiveRate >= 160_000 {
                bounds = CGSize(width: 480, height: 270)
                fps = 20
            } else {
                bounds = CGSize(width: 320, height: 180)
                fps = 15
            }
        }
        if preset != .maximum, sourceSize.height > sourceSize.width, bounds.width > bounds.height {
            bounds = CGSize(width: bounds.height, height: bounds.width)
        }
        let size = CaptureSizing.fit(source: sourceSize, inside: bounds, allowUpscale: false)
        if preset != .maximum && preset != .custom {
            // Small regions need fewer bits than a full frame; maintain tier spacing.
            let pixelFraction = Double(size.width * size.height / (bounds.width * bounds.height))
            bitrate = Int(Double(bitrate) * max(0.2, pixelFraction))
        }
        if let sourceVideoBitrate, sourceVideoBitrate.isFinite, sourceVideoBitrate > 0 {
            let fraction: Double
            switch preset {
            case .maximum: fraction = 1
            case .balanced: fraction = 0.5
            case .compact: fraction = 0.2
            case .tiny: fraction = 0.08
            case .custom: fraction = 1
            }
            bitrate = min(bitrate, max(80_000, Int(sourceVideoBitrate * fraction)))
        }
        return VideoExportPlan(
            size: CaptureSizing.evenSize(width: size.width * resolutionScale, height: size.height * resolutionScale),
            frameRate: fps,
            videoBitrate: max(80_000, Int(Double(bitrate) * bitrateScale)),
            audioBitrate: audioRate,
            byteLimit: limit
        )
    }

    static func validatedName(_ input: String, fallback: String) throws -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".mp4") { name.removeLast(4) }
        if name.isEmpty { name = fallback }
        guard name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              name.utf8.count <= 180 else {
            throw CaptureError.couldNotFinishWriter("名称不能以句点开头、包含 / 或 :，或超过 180 字节。")
        }
        return name
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
