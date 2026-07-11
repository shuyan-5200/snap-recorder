import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

enum RecordingDiagnostics {
    static func run() async throws -> String {
        try validateCaptureSizing()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapRecorder-self-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputSize = CGSize(width: 640, height: 360)
        let sourceSize = CGSize(width: 520, height: 300)
        let writer = try RecordingWriter(
            outputURL: outputURL,
            outputSize: outputSize,
            mode: .browser,
            capturesAudio: false,
            wallpaperURL: nil
        )

        let context = CIContext(options: [.useSoftwareRenderer: false])
        var firstFrameTime = CMTime.invalid
        var wroteFrameAfterPause = false
        for frame in 0..<24 {
            if let frameTime = try appendFrame(
                number: frame,
                sourceSize: sourceSize,
                writer: writer,
                context: context
            ) {
                if !firstFrameTime.isValid {
                    firstFrameTime = frameTime
                }
            }
            try await Task.sleep(for: .milliseconds(34))
        }

        writer.pause()
        let pauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
        try await Task.sleep(for: .milliseconds(800))
        let pauseEndedAt = CMClockGetTime(CMClockGetHostTimeClock())
        writer.resume()

        for frame in 24..<48 {
            if let frameTime = try appendFrame(
                number: frame,
                sourceSize: sourceSize,
                writer: writer,
                context: context
            ) {
                if !firstFrameTime.isValid {
                    firstFrameTime = frameTime
                }
                wroteFrameAfterPause = true
            }
            try await Task.sleep(for: .milliseconds(34))
        }

        let expectedEndTime = CMClockGetTime(CMClockGetHostTimeClock())
        try await writer.finish()

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw CaptureError.couldNotFinishWriter("自检视频没有视频轨道。")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0

        let measuredPause = CMTimeSubtract(pauseEndedAt, pauseStartedAt)
        let expectedDuration = CMTimeSubtract(
            CMTimeSubtract(
                expectedEndTime,
                firstFrameTime
            ),
            measuredPause
        ).seconds

        guard firstFrameTime.isValid,
              wroteFrameAfterPause,
              measuredPause.seconds > 0.6,
              duration > 1.2,
              duration < 15,
              abs(duration - expectedDuration) < 0.35,
              Int(naturalSize.width) == Int(outputSize.width),
              Int(naturalSize.height) == Int(outputSize.height),
              fileSize > 20_000 else {
            throw CaptureError.couldNotFinishWriter(
                "自检结果异常（时长 \(duration)，预期 \(expectedDuration)，尺寸 \(naturalSize)，文件 \(fileSize) bytes）。"
            )
        }

        let voiceReport = try await validateVoiceExport()
        let voiceOnlyReport = try await validateVoiceOnlyExport()
        return "Snap Recorder self-test passed: \(String(format: "%.2f", duration))s, \(Int(naturalSize.width))x\(Int(naturalSize.height)), \(fileSize) bytes; \(voiceReport); \(voiceOnlyReport)"
    }

    private static func validateVoiceOnlyExport() async throws -> String {
        let directory = FileManager.default.temporaryDirectory
        let videoURL = directory.appendingPathComponent("SnapRecorder-voice-only-\(UUID().uuidString).mp4")
        let voiceURL = directory.appendingPathComponent("SnapRecorder-voice-only-\(UUID().uuidString).m4a")
        let combinedURL = directory.appendingPathComponent("SnapRecorder-voice-only-\(UUID().uuidString)-combined.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: voiceURL)
            try? FileManager.default.removeItem(at: combinedURL)
        }

        let outputSize = CGSize(width: 320, height: 180)
        let writer = try RecordingWriter(
            outputURL: videoURL,
            outputSize: outputSize,
            mode: .browser,
            capturesAudio: false,
            microphoneOutputURL: voiceURL,
            wallpaperURL: nil
        )
        let context = CIContext(options: [.useSoftwareRenderer: false])
        for frame in 0..<24 {
            try appendFrame(
                number: frame,
                sourceSize: CGSize(width: 280, height: 160),
                writer: writer,
                context: context
            )
            let voice = try makeAudioSampleBuffer(chunk: frame, frequency: 880)
            guard writer.appendMicrophone(voice) else {
                throw CaptureError.couldNotFinishWriter("仅人声自检无法写入麦克风样本。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await writer.finish()
        try await RecordingExporter.combine(
            videoURL: videoURL,
            microphoneURL: voiceURL,
            outputURL: combinedURL
        )

        let sourceAsset = AVURLAsset(url: videoURL)
        let combinedAsset = AVURLAsset(url: combinedURL)
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        let combinedAudioTracks = try await combinedAsset.loadTracks(withMediaType: .audio)
        let sourceSignature = try await videoSampleSignature(at: videoURL)
        let combinedSignature = try await videoSampleSignature(at: combinedURL)
        guard sourceAudioTracks.isEmpty,
              combinedAudioTracks.count == 1,
              sourceSignature == combinedSignature else {
            throw CaptureError.couldNotFinishWriter("仅人声合并自检异常。")
        }
        return "voice-only mix passed"
    }

    private static func validateVoiceExport() async throws -> String {
        let directory = FileManager.default.temporaryDirectory
        let videoURL = directory.appendingPathComponent("SnapRecorder-audio-test-\(UUID().uuidString).mp4")
        let voiceURL = directory.appendingPathComponent("SnapRecorder-audio-test-\(UUID().uuidString).m4a")
        let alignedVoiceURL = directory.appendingPathComponent("SnapRecorder-audio-test-\(UUID().uuidString)-aligned.m4a")
        let combinedURL = directory.appendingPathComponent("SnapRecorder-audio-test-\(UUID().uuidString)-combined.mp4")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: voiceURL)
            try? FileManager.default.removeItem(at: alignedVoiceURL)
            try? FileManager.default.removeItem(at: combinedURL)
        }

        let outputSize = CGSize(width: 320, height: 180)
        let sourceSize = CGSize(width: 280, height: 160)
        let writer = try RecordingWriter(
            outputURL: videoURL,
            outputSize: outputSize,
            mode: .browser,
            capturesAudio: true,
            microphoneOutputURL: voiceURL,
            wallpaperURL: nil
        )
        let context = CIContext(options: [.useSoftwareRenderer: false])

        for frame in 0..<30 {
            try appendFrame(
                number: frame,
                sourceSize: sourceSize,
                writer: writer,
                context: context
            )
            let systemSample = try makeAudioSampleBuffer(chunk: frame, frequency: 440)
            let voiceSample = try makeAudioSampleBuffer(chunk: frame, frequency: 880)
            writer.appendAudio(systemSample)
            guard writer.appendMicrophone(voiceSample) else {
                throw CaptureError.couldNotFinishWriter("自检无法写入人声音轨。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        writer.pause()
        try await Task.sleep(for: .milliseconds(150))
        writer.resume()

        for frame in 30..<60 {
            try appendFrame(
                number: frame,
                sourceSize: sourceSize,
                writer: writer,
                context: context
            )
            let systemSample = try makeAudioSampleBuffer(chunk: frame, frequency: 440)
            let voiceSample = try makeAudioSampleBuffer(chunk: frame, frequency: 880)
            writer.appendAudio(systemSample)
            guard writer.appendMicrophone(voiceSample) else {
                throw CaptureError.couldNotFinishWriter("自检无法继续写入人声音轨。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        try await writer.finish()
        try await RecordingExporter.combine(
            videoURL: videoURL,
            microphoneURL: voiceURL,
            outputURL: combinedURL
        )
        try await RecordingExporter.alignVoice(
            microphoneURL: voiceURL,
            matchingVideoURL: videoURL,
            outputURL: alignedVoiceURL
        )

        let videoAsset = AVURLAsset(url: videoURL)
        let voiceAsset = AVURLAsset(url: alignedVoiceURL)
        let combinedAsset = AVURLAsset(url: combinedURL)
        let videoDuration = try await videoAsset.load(.duration).seconds
        let voiceDuration = try await voiceAsset.load(.duration).seconds
        let combinedDuration = try await combinedAsset.load(.duration).seconds
        let combinedVideoTracks = try await combinedAsset.loadTracks(withMediaType: .video)
        let combinedAudioTracks = try await combinedAsset.loadTracks(withMediaType: .audio)
        let combinedSize = try await combinedVideoTracks.first?.load(.naturalSize) ?? .zero
        let sourceVideoSignature = try await videoSampleSignature(at: videoURL)
        let combinedVideoSignature = try await videoSampleSignature(at: combinedURL)

        guard abs(videoDuration - voiceDuration) <= 0.04,
              abs(videoDuration - combinedDuration) <= 0.04,
              combinedVideoTracks.count == 1,
              combinedAudioTracks.count == 1,
              combinedSize == outputSize,
              sourceVideoSignature == combinedVideoSignature else {
            throw CaptureError.couldNotFinishWriter(
                "人声导出自检异常（视频 \(videoDuration)s，人声 \(voiceDuration)s，合并 \(combinedDuration)s）。"
            )
        }

        let transactionReport = try await validateDualExportTransaction(
            videoURL: videoURL,
            voiceURL: voiceURL
        )
        return "voice mix passed, aligned within 40ms; \(transactionReport)"
    }

    private static func validateDualExportTransaction(
        videoURL: URL,
        voiceURL: URL
    ) async throws -> String {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("SnapRecorder-export-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let sourceVideoURL = directory.appendingPathComponent("source.mp4")
        let sourceVoiceURL = directory.appendingPathComponent("source.m4a")
        try fileManager.copyItem(at: videoURL, to: sourceVideoURL)
        try fileManager.copyItem(at: voiceURL, to: sourceVoiceURL)

        let desiredVideoURL = directory.appendingPathComponent(TimeFormatting.outputFilename())
        guard fileManager.createFile(atPath: desiredVideoURL.path, contents: Data()) else {
            throw CaptureError.couldNotFinishWriter("自检无法创建重名占位文件。")
        }

        let service = ScreenCaptureService()
        try service.installPendingRecordingForSelfTest(
            videoURL: sourceVideoURL,
            microphoneURL: sourceVoiceURL,
            finalVideoURL: desiredVideoURL
        )
        let result = try await service.exportPendingRecording(Set(VoiceExportMode.allCases))
        let outputNames = result.urls.map(\.lastPathComponent)
        let prefixes = ["Snap 录屏 ", "Snap 视频 ", "Snap 人声 "]
        let placeholderAttributes = try fileManager.attributesOfItem(
            atPath: desiredVideoURL.path
        )
        let placeholderSize = (placeholderAttributes[.size] as? NSNumber)?.intValue
        let outputSizes = try result.urls.map { url in
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        }

        guard outputNames.count == 3,
              zip(outputNames, prefixes).allSatisfy({ name, prefix in
                  name.hasPrefix(prefix) && name.contains(" (2)")
              }),
              result.urls.allSatisfy({ fileManager.fileExists(atPath: $0.path) }),
              outputSizes.allSatisfy({ $0 > 0 }),
              !fileManager.fileExists(atPath: sourceVideoURL.path),
              !fileManager.fileExists(atPath: sourceVoiceURL.path),
              placeholderSize == 0 else {
            throw CaptureError.couldNotFinishWriter(
                "三文件导出事务或统一重名后缀自检异常。"
            )
        }
        return "3-file transaction passed"
    }

    private static func videoSampleSignature(at url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.couldNotFinishWriter("自检文件没有可比对的视频轨道。")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CaptureError.couldNotFinishWriter("自检无法读取压缩视频样本。")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CaptureError.couldNotFinishWriter("自检无法开始读取压缩视频样本。")
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        var sampleCount = 0
        var totalBytes = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(dataBuffer)
            var bytes = [UInt8](repeating: 0, count: length)
            let status = CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: length,
                destination: &bytes
            )
            guard status == kCMBlockBufferNoErr else {
                throw CaptureError.couldNotFinishWriter("自检无法读取压缩视频数据。")
            }
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
            }
            sampleCount += 1
            totalBytes += length
        }
        guard reader.status == .completed else {
            throw CaptureError.couldNotFinishWriter(
                reader.error?.localizedDescription ?? "压缩视频比对中断。"
            )
        }
        return "\(sampleCount):\(totalBytes):\(String(hash, radix: 16))"
    }

    private static func makeAudioSampleBuffer(
        chunk: Int,
        frequency: Double
    ) throws -> CMSampleBuffer {
        let sampleRate = 48_000.0
        let sampleCount = 960
        var samples = [Int16](repeating: 0, count: sampleCount)
        for index in samples.indices {
            let sampleIndex = chunk * sampleCount + index
            let value = sin(2 * Double.pi * frequency * Double(sampleIndex) / sampleRate)
            samples[index] = Int16(value * Double(Int16.max) * 0.18)
        }

        var blockBuffer: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Int16>.size
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw CaptureError.couldNotStartWriter("自检无法创建声音缓冲区。")
        }
        let copyStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw CaptureError.couldNotStartWriter("自检无法填充声音缓冲区。")
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw CaptureError.couldNotStartWriter("自检无法描述声音格式。")
        }

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sampleCount,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CaptureError.couldNotStartWriter("自检无法创建声音样本。")
        }
        return sampleBuffer
    }

    private static func validateCaptureSizing() throws {
        let browserSources = [
            CGSize(width: 2_882, height: 1_898),
            CGSize(width: 3_024, height: 1_964),
            CGSize(width: 1_920, height: 1_080),
            CGSize(width: 3_840, height: 2_160),
            CGSize(width: 5_120, height: 2_880),
            CGSize(width: 2_731, height: 1_535)
        ]

        for source in browserSources {
            let layout = CaptureSizing.browserLayout(source: source)
            let sourceRatio = source.width / source.height
            let outputRatio = layout.outputSize.width / layout.outputSize.height
            let streamRatio = layout.streamSize.width / layout.streamSize.height
            let widthFill = layout.streamSize.width / layout.outputSize.width
            let heightFill = layout.streamSize.height / layout.outputSize.height

            guard isEven(layout.outputSize.width),
                  isEven(layout.outputSize.height),
                  isEven(layout.streamSize.width),
                  isEven(layout.streamSize.height),
                  layout.outputSize.width <= CaptureSizing.maximumHighDefinitionOutputSize.width,
                  layout.outputSize.height <= CaptureSizing.maximumHighDefinitionOutputSize.height,
                  layout.streamSize.width <= source.width,
                  layout.streamSize.height <= source.height,
                  relativeDifference(outputRatio, sourceRatio) < 0.005,
                  relativeDifference(streamRatio, sourceRatio) < 0.005,
                  widthFill >= 0.94,
                  heightFill >= 0.94,
                  layout.contentRect.minX.rounded() == layout.contentRect.minX,
                  layout.contentRect.minY.rounded() == layout.contentRect.minY,
                  layout.contentRect.minX > 0,
                  layout.contentRect.minY > 0,
                  layout.contentRect.maxX < layout.outputSize.width,
                  layout.contentRect.maxY < layout.outputSize.height else {
                throw CaptureError.couldNotFinishWriter(
                    "浏览器布局自检异常（源 \(source)，输出 \(layout.outputSize)，采集 \(layout.streamSize)）。"
                )
            }
        }

        let nativeBrowserLayout = CaptureSizing.browserLayout(
            source: CGSize(width: 2_882, height: 1_898)
        )
        guard nativeBrowserLayout.outputSize == CGSize(width: 3_034, height: 1_998),
              nativeBrowserLayout.streamSize == CGSize(width: 2_882, height: 1_898) else {
            throw CaptureError.couldNotFinishWriter(
                "原生浏览器像素自检异常（输出 \(nativeBrowserLayout.outputSize)，采集 \(nativeBrowserLayout.streamSize)）。"
            )
        }

        let displaySize = CaptureSizing.fit(
            source: CGSize(width: 3_024, height: 1_964),
            inside: CaptureSizing.maximumHighDefinitionOutputSize,
            allowUpscale: false
        )
        guard displaySize == CGSize(width: 3_024, height: 1_964),
              RecordingQuality.videoBitrate(for: nativeBrowserLayout.outputSize) == 48_495_456,
              RecordingQuality.videoBitrate(
                for: CaptureSizing.maximumHighDefinitionOutputSize
              ) == 66_355_200 else {
            throw CaptureError.couldNotFinishWriter(
                "高清输出自检异常（整屏 \(displaySize)）。"
            )
        }
    }

    private static func isEven(_ value: CGFloat) -> Bool {
        Int(value) % 2 == 0
    }

    private static func relativeDifference(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        abs(lhs - rhs) / rhs
    }

    @discardableResult
    private static func appendFrame(
        number: Int,
        sourceSize: CGSize,
        writer: RecordingWriter,
        context: CIContext
    ) throws -> CMTime? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(sourceSize.width),
            Int(sourceSize.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CaptureError.couldNotStartWriter("自检无法创建画面缓冲区。")
        }

        let hue = CGFloat(number % 48) / 48
        let background = CIImage(
            color: CIColor(red: 0.12 + hue * 0.35, green: 0.28, blue: 0.62 - hue * 0.25)
        ).cropped(to: CGRect(origin: .zero, size: sourceSize))
        let markerX = CGFloat(number) / 47 * (sourceSize.width - 70)
        let marker = CIImage(color: .white)
            .cropped(to: CGRect(x: markerX, y: 108, width: 70, height: 70))
        context.render(
            marker.composited(over: background),
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: sourceSize),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        var formatDescription: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descriptionStatus == noErr, let formatDescription else {
            throw CaptureError.couldNotStartWriter("自检无法描述画面格式。")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CaptureError.couldNotStartWriter("自检无法创建视频帧。")
        }

        return writer.appendVideo(sampleBuffer) ? timing.presentationTimeStamp : nil
    }
}
