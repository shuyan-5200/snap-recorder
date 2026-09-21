import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// Generated media only: these tests never request screen, microphone or camera access.
enum ExportDiagnostics {
    static func run() async throws -> String {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("SnapRecorder-export-benchmark-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        try await makeFixture(at: source)
        let sourceBytes = try ExportPlanning.fileBytes(source)
        let service = ScreenCaptureService()
        try service.installPendingRecordingForSelfTest(videoURL: source, microphoneURL: nil,
                                                       finalVideoURL: directory.appendingPathComponent("export.mp4"))
        var report: [String] = ["legacy 1080p60 master: \(sourceBytes) bytes"]
        var sizes: [Int64] = []
        for preset in [RecordingQualityPreset.maximum, .balanced, .compact, .tiny] {
            let result = try await service.exportPendingRecording(qualityPreset: preset, selection: RecordingExportSelection(tracks: [.video], arrangement: .merged), name: preset.rawValue)
            let url = result.urls[0]
            let bytes = try ExportPlanning.fileBytes(url)
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let dimensions = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            let rate = try await track.load(.nominalFrameRate)
            let plan = try ExportPlanning.plan(sourceSize: CGSize(width: 1920, height: 1080),
                                               duration: 4, preset: preset, hasSystemAudio: false)
            guard dimensions.width <= plan.size.width, dimensions.height <= plan.size.height,
                  dimensions.width / dimensions.height > 1.75, abs(duration - 4) < 0.06,
                  abs(rate - Float(ExportPlanning.frameRate)) < 0.1 else {
                throw failure("\(preset.title)尺寸、帧率或时长不符合计划。")
            }
            if preset == .maximum {
                let psnr = try await compareFrames(source, url)
                // A legacy 60 fps master cannot be copied as a quality fallback.
                // Its changing detail may also differ between 30 fps sample points.
                guard psnr >= 24 else { throw failure("旧版原片降帧后画面误差过大：\(psnr) dB。") }
                report.append(String(format: "30 fps high PSNR versus legacy master: %.2f dB", psnr))
            }
            sizes.append(bytes)
            report.append("\(preset.title): \(Int(dimensions.width))x\(Int(dimensions.height)) \(rate)fps, \(bytes) bytes")
        }
        guard zip(sizes, sizes.dropFirst()).allSatisfy({ $0 > $1 * 12 / 10 }),
              sizes[0] <= sourceBytes, sizes[3] < sizes[0] / 5 else {
            throw failure("实际文件体积梯度不足：\(sizes)，原片 \(sourceBytes)。")
        }
        print("EXPORT BENCHMARK (synthetic, 4s):\n" + report.joined(separator: "\n"))
        fflush(stdout)
        let legacyCustom = try await service.exportPendingRecording(qualityPreset: .custom, selection: RecordingExportSelection(tracks: [.video], arrangement: .merged),
                                                                    name: "旧原片转30帧", customMegabytes: 20)
        let customTrack = try await AVURLAsset(url: legacyCustom.urls[0]).loadTracks(withMediaType: .video)[0]
        let customRate = try await customTrack.load(.nominalFrameRate)
        guard abs(customRate - Float(ExportPlanning.frameRate)) < 0.1,
              try Data(contentsOf: source) != Data(contentsOf: legacyCustom.urls[0]) else {
            throw failure("旧版60帧原片未转换为30帧。")
        }
        let nativePlan = try ExportPlanning.plan(sourceSize: CGSize(width: 1920, height: 1080),
            duration: 4, preset: .custom, customMegabytes: 20, hasSystemAudio: false,
            sourceFrameRate: 30, sourceBytes: sourceBytes)
        guard nativePlan.preservesSource, nativePlan.frameRate == ExportPlanning.frameRate else {
            throw failure("原生30帧原片未保留直通路径。")
        }
        let recommendation = try ExportPlanning.customSizeRecommendation(
            sourceSize: CGSize(width: 1920, height: 1080), duration: 4,
            hasSystemAudio: false, sourceVideoBitrate: nil, sourceBytes: sourceBytes,
            includesCombinedVoice: false
        )
        guard recommendation.minimum * 1_000_000 >= Double(sizes[3]),
              recommendation.suggestedMaximum >= recommendation.minimum else {
            throw failure("自定义建议范围低于“极小”档的实际大小。")
        }
        do {
            _ = try ExportPlanning.plan(sourceSize: CGSize(width: 1920, height: 1080),
                duration: 4, preset: .custom, customMegabytes: recommendation.minimum - 0.1,
                hasSystemAudio: false, sourceBytes: sourceBytes)
            throw failure("低于“极小”档预算的上限被接受。")
        } catch let error as CaptureError {
            guard error.localizedDescription.contains("极小") else { throw error }
        }
        let custom = try await service.exportPendingRecording(qualityPreset: .custom, selection: RecordingExportSelection(tracks: [.video], arrangement: .merged),
                                                               name: "大小上限", customMegabytes: 0.35)
        guard try ExportPlanning.fileBytes(custom.urls[0]) <= 350_000 else {
            throw failure("自定义大小超限。")
        }
        // Cancellation and validation failures must leave the same source available for retry.
        let cancelled = Task { try await service.exportPendingRecording(qualityPreset: .balanced, selection: RecordingExportSelection(tracks: [.video], arrangement: .merged), name: "取消") }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw failure("取消后仍然导出了文件。") }
        catch is CancellationError {}
        do {
            _ = try await service.exportPendingRecording(qualityPreset: .custom, selection: RecordingExportSelection(tracks: [.video], arrangement: .merged), customMegabytes: .nan)
            throw failure("非法大小被接受。")
        } catch let error as CaptureError {
            guard error.localizedDescription.contains("极小") else { throw error }
        }
        for name in ["../越界", "a/b", ".hidden", "a:b", String(repeating: "名", count: 100)] {
            do { _ = try ExportPlanning.validatedName(name, fallback: "test"); throw failure("非法名称被接受。") }
            catch let error as CaptureError {
                guard error.localizedDescription.contains("名称") else { throw error }
            }
        }
        guard try ExportPlanning.validatedName("  项目一.mp4  ", fallback: "test") == "项目一",
              try ExportPlanning.validatedName("", fallback: "fallback") == "fallback" else {
            throw failure("名称处理异常。")
        }
        let retry = try await service.exportPendingRecording(qualityPreset: .tiny, selection: RecordingExportSelection(tracks: [.video], arrangement: .merged), name: "重试成功")
        guard fm.fileExists(atPath: source.path), !retry.urls.isEmpty else { throw failure("取消后原片丢失。") }
        try service.discardPendingRecording()
        guard !service.hasPendingRecording, !fm.fileExists(atPath: source.path),
              fm.fileExists(atPath: retry.urls[0].path) else { throw failure("清理边界异常。") }
        // A failed destination must not destroy the master.
        try await makeFixture(at: source, seconds: 0.3)
        let blocker = directory.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: blocker)
        try service.installPendingRecordingForSelfTest(videoURL: source, microphoneURL: nil,
                                                       finalVideoURL: blocker.appendingPathComponent("failed.mp4"))
        var destinationFailed = false
        do {
            _ = try await service.exportPendingRecording(qualityPreset: .tiny, selection: RecordingExportSelection(tracks: [.video], arrangement: .merged))
        } catch {
            destinationFailed = true
            guard fm.fileExists(atPath: source.path), service.hasPendingRecording,
                  (try? Data(contentsOf: blocker)) == Data([1]) else { throw failure("失败清理破坏了原片或已有文件。") }
        }
        guard destinationFailed else { throw failure("不可写目标没有失败。") }
        try service.discardPendingRecording()
        return "4-tier measured sizes, custom ceiling, cancellation, retry and naming passed"
    }

    static func makeFixture(at url: URL, seconds: Double = 4) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: RecordingQuality.settings(
            size: CGSize(width: 1920, height: 1080), bitrate: 24_000_000, frameRate: 60,
            reordersFrames: false, prioritizesQuality: true
        ))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw failure("基准原片无法启动。") }
        writer.startSession(atSourceTime: .zero)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        for frame in 0..<Int(seconds * 60) {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw failure("基准原片写入中断。") }
                try await Task.sleep(for: .milliseconds(2))
            }
            try autoreleasepool {
                var optionalBuffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                      let buffer = optionalBuffer else { throw failure("无法创建基准画面。") }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw failure("无法绘制基准。") }
                context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
                for line in 0..<28 {
                    let text = "Project \(line + 1)   Meeting notes / Export details   0123456789   Aa Bb Cc"
                    let attributes: [NSAttributedString.Key: Any] = [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)
                    ]
                    let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                    context.textPosition = CGPoint(x: 40, y: 45 + line * 36)
                    CTLineDraw(ctLine, context)
                }
                // Deterministic moving detail, analogous to a video/camera region beside text.
                for y in stride(from: 0, to: 1080, by: 8) {
                    for x in stride(from: 960, to: 1920, by: 8) {
                        let hash = (UInt64(x * 17 + y * 37 + frame * 7907) &* 2_654_435_761)
                        let v = Double((hash ^ (hash >> 13)) % 255) / 255
                        context.setFillColor(CGColor(red: v, green: 0.3 + v * 0.5, blue: 1 - v * 0.8, alpha: 1))
                        context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                    }
                }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)) else {
                    throw failure(writer.error?.localizedDescription ?? "基准画面写入失败。")
                }
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await withCheckedContinuation { c in writer.finishWriting { c.resume() } }
        guard writer.status == .completed else { throw failure("基准文件未完成。") }
    }

    static func makeToneFile(at url: URL, frequency: Double, seconds: Double) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000
        ])
        let count = AVAudioFrameCount(seconds * 48_000)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
              let channel = buffer.floatChannelData?[0] else { throw failure("无法创建声音样本。") }
        buffer.frameLength = count
        for i in 0..<Int(count) {
            channel[i] = Float(sin(2 * Double.pi * frequency * Double(i) / 48_000) * 0.18)
        }
        try file.write(from: buffer)
    }

    private static func compareFrames(_ first: URL, _ second: URL) async throws -> Double {
        func pixels(_ url: URL) async throws -> [UInt8] {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(value: 30, timescale: 60)).image
            var bytes = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: 1920, height: 1080, bitsPerComponent: 8,
                                    bytesPerRow: 1920 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            }
            return bytes
        }
        let a = try await pixels(first), b = try await pixels(second)
        var error = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { error += pow(Double(a[i+c]) - Double(b[i+c]), 2) }
        }
        return 10 * log10(255 * 255 / max(0.0001, error / Double(1920 * 1080 * 3)))
    }

    static func validateToneIsolation(video: URL, voice: URL) async throws {
        try await validateTones(url: video, system: true, voice: false)
        try await validateTones(url: voice, system: false, voice: true)
    }

    static func validateTones(url: URL, system: Bool, voice: Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw failure("缺少音轨。") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { throw failure("无法解码声音隔离测试。") }
        var powers = [0.0, 0.0]
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block) / 4
            var values = [Float](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!)
            }
            for (index, frequency) in [440.0, 880.0].enumerated() {
                var real = 0.0, imaginary = 0.0
                for (i, value) in values.enumerated() {
                    let angle = 2 * Double.pi * frequency * Double(i) / 48_000
                    real += Double(value) * cos(angle)
                    imaginary += Double(value) * sin(angle)
                }
                powers[index] += real * real + imaginary * imaginary
            }
        }
        let valid: Bool
        if system && voice { valid = powers.min()! > 1 && powers.min()! * 10 > powers.max()! }
        else if system { valid = powers[0] > 1 && powers[0] > powers[1] * 36 }
        else { valid = powers[1] > 1 && powers[1] > powers[0] * 36 }
        guard reader.status == .completed, valid else { throw failure("声音内容不符合勾选：\(url.lastPathComponent)。") }
    }

    private static func failure(_ message: String) -> CaptureError { .couldNotFinishWriter("导出自检：" + message) }
}
