import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// AVAssetExportSession supports cancellation from another thread. Only that
// operation crosses the cancellation-handler boundary; export remains sequential.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

enum RecordingExporter {
    static func compressVideo(
        sourceURL: URL,
        outputURL: URL,
        plan: VideoExportPlan,
        includesAudio: Bool = true
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        guard duration.isValid,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) > 0,
              let sourceVideoTrack = try await asset
                .loadTracks(withMediaType: .video).first else {
            throw CaptureError.couldNotFinishWriter("无法读取待压缩的视频轨道。")
        }

        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let transform = try await sourceVideoTrack.load(.preferredTransform)
        let sourceBounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = plan.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(plan.frameRate))
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVideoTrack)
        let fittedTransform = transform
            .concatenating(CGAffineTransform(translationX: -sourceBounds.minX, y: -sourceBounds.minY))
            .concatenating(CGAffineTransform(scaleX: plan.size.width / sourceBounds.width,
                                            y: plan.size.height / sourceBounds.height))
        layer.setTransform(fittedTransform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [sourceVideoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw CaptureError.couldNotFinishWriter("无法解码待压缩的画面。")
        }
        reader.add(videoOutput)

        let sourceAudioTrack = includesAudio ? try await asset.loadTracks(withMediaType: .audio).first : nil
        let audioOutput = sourceAudioTrack.map {
            AVAssetReaderTrackOutput(track: $0, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
        }
        if let audioOutput {
            audioOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(audioOutput) else {
                throw CaptureError.couldNotFinishWriter("无法读取原始电脑声音。")
            }
            reader.add(audioOutput)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let qualitySettings = RecordingQuality.settings(
            size: plan.size, bitrate: plan.videoBitrate, frameRate: plan.frameRate,
            reordersFrames: true, prioritizesQuality: true, limitsDataRate: true
        )
        let baseSettings = RecordingQuality.settings(
            size: plan.size, bitrate: plan.videoBitrate, frameRate: plan.frameRate,
            reordersFrames: true, prioritizesQuality: false, limitsDataRate: true
        )
        let videoSettings = writer.canApply(
            outputSettings: qualitySettings,
            forMediaType: .video
        ) ? qualitySettings : baseSettings
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw CaptureError.couldNotFinishWriter("当前设备不支持小体积视频编码。")
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw CaptureError.couldNotFinishWriter("无法创建小体积视频轨道。")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if sourceAudioTrack != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: max(64_000, plan.audioBitrate)
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw CaptureError.couldNotFinishWriter("无法保留原始电脑声音。")
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw CaptureError.couldNotFinishWriter(
                writer.error?.localizedDescription ?? "小体积编码器启动失败。"
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw CaptureError.couldNotFinishWriter(
                reader.error?.localizedDescription ?? "无法开始读取录制原片。"
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            if let audioOutput, let audioInput {
                async let videoPump: Void = pump(
                    output: videoOutput,
                    input: videoInput,
                    reader: reader,
                    writer: writer,
                    label: "小体积画面"
                )
                async let audioPump: Void = pump(
                    output: audioOutput,
                    input: audioInput,
                    reader: reader,
                    writer: writer,
                    label: "电脑声音"
                )
                _ = try await (videoPump, audioPump)
            } else {
                try await pump(
                    output: videoOutput,
                    input: videoInput,
                    reader: reader,
                    writer: writer,
                    label: "小体积画面"
                )
            }

            guard reader.status == .completed else {
                throw CaptureError.couldNotFinishWriter(
                    reader.error?.localizedDescription ?? "读取录制原片时中断。"
                )
            }

            writer.endSession(atSourceTime: duration)
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            guard writer.status == .completed else {
                throw CaptureError.couldNotFinishWriter(
                    writer.error?.localizedDescription ?? "小体积视频没有完成封装。"
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    /// Reject a nominally smaller high-quality export if sampled decoded frames lose too much detail.
    /// This is an objective guard, not a claim of perceptually lossless compression.
    static func preservesHighQuality(sourceURL: URL, candidateURL: URL, duration: Double) async throws -> Bool {
        let source = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        let candidate = AVAssetImageGenerator(asset: AVURLAsset(url: candidateURL))
        for generator in [source, candidate] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .zero
        }
        for fraction in [0.2, 0.5, 0.8] {
            try Task.checkCancellation()
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            let originalFrame = try await source.image(at: time)
            let original = originalFrame.image
            let alignedSeconds = ceil(max(0, originalFrame.actualTime.seconds * 60 - 0.00001)) / 60
            candidate.requestedTimeToleranceBefore = .zero
            candidate.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
            let encoded = try await candidate.image(at: CMTime(seconds: alignedSeconds, preferredTimescale: 600)).image
            let width = original.width, height = original.height
            guard width == encoded.width, height == encoded.height else { return false }
            func bytes(_ image: CGImage) -> [UInt8] {
                var output = [UInt8](repeating: 0, count: width * height * 4)
                output.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
                return output
            }
            let a = bytes(original), b = bytes(encoded)
            var squaredError = 0.0
            for i in stride(from: 0, to: a.count, by: 4) {
                for channel in 0..<3 {
                    let delta = Double(a[i + channel]) - Double(b[i + channel])
                    squaredError += delta * delta
                }
            }
            let mse = squaredError / Double(width * height * 3)
            let psnr = 10 * log10(255 * 255 / max(mse, 0.0001))
            if psnr < 32 { return false }
        }
        return true
    }

    static func alignVoice(microphoneURL: URL, matchingVideoURL: URL, outputURL: URL) async throws {
        try await alignAudio(sourceURL: microphoneURL, matchingVideoURL: matchingVideoURL, outputURL: outputURL)
    }

    static func copyVideoOnly(sourceURL: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.couldNotFinishWriter("没有视频画面。")
        }
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: duration))
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.couldNotFinishWriter("无法创建视频文件。")
        }
        try video.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        video.preferredTransform = try await track.load(.preferredTransform)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.couldNotFinishWriter("无法单独导出视频。")
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try Task.checkCancellation()
        let cancellation = ExportCancellation(session)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw CaptureError.couldNotFinishWriter(session.error?.localizedDescription ?? "视频导出未完成。")
        }
    }

    static func alignAudio(
        sourceURL: URL,
        matchingVideoURL: URL,
        outputURL: URL,
        channels: Int = 1
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let videoAsset = AVURLAsset(url: matchingVideoURL)
        let targetDuration = try await videoAsset.load(.duration)
        let microphoneAsset = AVURLAsset(url: sourceURL)
        guard targetDuration.isValid,
              targetDuration.isNumeric,
              CMTimeCompare(targetDuration, .zero) > 0,
              let microphoneTrack = try await microphoneAsset
                .loadTracks(withMediaType: .audio).first else {
            throw CaptureError.couldNotFinishWriter("无法读取待对齐的音频文件。")
        }

        let reader = try AVAssetReader(asset: microphoneAsset)
        reader.timeRange = CMTimeRange(start: .zero, duration: targetDuration)
        let output = AVAssetReaderTrackOutput(
            track: microphoneTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CaptureError.couldNotFinishWriter("无法解码音频音轨。")
        }
        reader.add(output)

        try writeAlignedAudio(reader: reader, output: output, targetDuration: targetDuration,
                              channels: channels, outputURL: outputURL)
    }

    private static func writeAlignedAudio(
        reader: AVAssetReader, output: AVAssetReaderOutput, targetDuration: CMTime,
        channels: Int, outputURL: URL
    ) throws {
        let fileManager = FileManager.default
        let sampleRate = 48_000.0
        let targetFrameCount = max(1, Int((targetDuration.seconds * sampleRate).rounded()))
        guard reader.startReading() else {
            throw CaptureError.couldNotFinishWriter(
                reader.error?.localizedDescription ?? "无法开始读取音频。"
            )
        }

        do {
            try autoreleasepool {
                let audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: channels,
                        AVEncoderBitRateKey: 192_000,
                        AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
                    ],
                    commonFormat: .pcmFormatInt16,
                    interleaved: true
                )
                let processingFormat = audioFile.processingFormat
                var writtenFrames = 0

                while let sampleBuffer = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
                    guard presentationTime.isValid,
                          presentationTime.isNumeric,
                          sampleCount > 0 else { continue }

                    let sampleStartFrame = max(
                        0,
                        Int((presentationTime.seconds * sampleRate).rounded())
                    )
                    if sampleStartFrame > writtenFrames {
                        let silenceCount = min(
                            sampleStartFrame - writtenFrames,
                            targetFrameCount - writtenFrames
                        )
                        if silenceCount > 0 {
                            try writeSilence(
                                frameCount: silenceCount,
                                format: processingFormat,
                                to: audioFile
                            )
                            writtenFrames += silenceCount
                        }
                    }

                    guard writtenFrames < targetFrameCount else { continue }
                    let sourceOffset = max(0, writtenFrames - sampleStartFrame)
                    let frameCount = min(
                        sampleCount - sourceOffset,
                        targetFrameCount - writtenFrames
                    )
                    guard frameCount > 0,
                          let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

                    guard let pcmBuffer = AVAudioPCMBuffer(
                        pcmFormat: processingFormat,
                        frameCapacity: AVAudioFrameCount(frameCount)
                    ), let destination = pcmBuffer.int16ChannelData?[0] else {
                        throw CaptureError.couldNotFinishWriter("无法创建音频 PCM 缓冲区。")
                    }
                    pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
                    let copyStatus = CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: sourceOffset * channels * MemoryLayout<Int16>.size,
                        dataLength: frameCount * channels * MemoryLayout<Int16>.size,
                        destination: destination
                    )
                    guard copyStatus == kCMBlockBufferNoErr else {
                        throw CaptureError.couldNotFinishWriter("无法读取音频 PCM 数据。")
                    }
                    try audioFile.write(from: pcmBuffer)
                    writtenFrames += frameCount
                }

                guard reader.status == .completed else {
                    throw CaptureError.couldNotFinishWriter(
                        reader.error?.localizedDescription ?? "读取音频时中断。"
                    )
                }
                if writtenFrames < targetFrameCount {
                    try writeSilence(
                        frameCount: targetFrameCount - writtenFrames,
                        format: processingFormat,
                        to: audioFile
                    )
                    writtenFrames = targetFrameCount
                }
                guard writtenFrames == targetFrameCount else {
                    throw CaptureError.couldNotFinishWriter("音频帧数没有与视频对齐。")
                }
            }
        } catch {
            reader.cancelReading()
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    static func combine(
        videoURL: URL,
        microphoneURL: URL,
        outputURL: URL,
        audioBitrate: Int = 192_000,
        includesSystemAudio: Bool = true,
        includesVideo: Bool = true
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let videoAsset = AVURLAsset(url: videoURL)
        let microphoneAsset = AVURLAsset(url: microphoneURL)
        let videoDuration = try await videoAsset.load(.duration)
        guard videoDuration.isValid, CMTimeCompare(videoDuration, .zero) > 0 else {
            throw CaptureError.couldNotFinishWriter("录制视频时长无效。")
        }

        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceMicrophoneTrack = try await microphoneAsset
                .loadTracks(withMediaType: .audio).first else {
            throw CaptureError.couldNotFinishWriter("合并所需的画面或人声音轨不存在。")
        }

        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration)
        )

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CaptureError.couldNotFinishWriter("无法准备高清视频轨道。")
        }

        let sourceVideoRange = try await sourceVideoTrack.load(.timeRange)
        try compositionVideoTrack.insertTimeRange(
            sourceVideoRange,
            of: sourceVideoTrack,
            at: .zero
        )
        compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        var compositionAudioTracks: [AVMutableCompositionTrack] = []
        var audioMixParameters: [AVAudioMixInputParameters] = []

        if includesSystemAudio, let sourceSystemTrack = try await videoAsset.loadTracks(withMediaType: .audio).first,
           let compositionSystemTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let range = try await sourceSystemTrack.load(.timeRange)
            let insertionTime = CMTimeMaximum(.zero, range.start)
            try compositionSystemTrack.insertTimeRange(range, of: sourceSystemTrack, at: insertionTime)
            compositionAudioTracks.append(compositionSystemTrack)

            let parameters = AVMutableAudioMixInputParameters(track: compositionSystemTrack)
            parameters.setVolume(0.78, at: .zero)
            audioMixParameters.append(parameters)
        }

        guard let compositionMicrophoneTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CaptureError.couldNotFinishWriter("无法准备人声音轨。")
        }
        let microphoneRange = try await sourceMicrophoneTrack.load(.timeRange)
        let microphoneInsertionTime = CMTimeMaximum(.zero, microphoneRange.start)
        try compositionMicrophoneTrack.insertTimeRange(
            microphoneRange,
            of: sourceMicrophoneTrack,
            at: microphoneInsertionTime
        )
        compositionAudioTracks.append(compositionMicrophoneTrack)

        let microphoneParameters = AVMutableAudioMixInputParameters(
            track: compositionMicrophoneTrack
        )
        microphoneParameters.setVolume(1, at: .zero)
        audioMixParameters.append(microphoneParameters)

        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: videoDuration)

        let videoOutput = AVAssetReaderTrackOutput(
            track: compositionVideoTrack,
            outputSettings: nil
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw CaptureError.couldNotFinishWriter("无法读取原始高清视频轨道。")
        }
        if includesVideo { reader.add(videoOutput) }

        let audioOutput = AVAssetReaderAudioMixOutput(
            audioTracks: compositionAudioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioMixParameters
        audioOutput.audioMix = audioMix
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            throw CaptureError.couldNotFinishWriter("无法读取待混合的声音轨道。")
        }
        reader.add(audioOutput)
        if !includesVideo {
            // Audio-only assets need explicit head/tail silence: an empty video
            // track does not extend the decoded audio timeline in an M4A writer.
            try writeAlignedAudio(reader: reader, output: audioOutput,
                                  targetDuration: videoDuration, channels: 2, outputURL: outputURL)
            return
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let formatDescriptions = try await sourceVideoTrack.load(.formatDescriptions)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescriptions.first
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = try await sourceVideoTrack.load(.preferredTransform)

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
        )
        audioInput.expectsMediaDataInRealTime = false

        guard (!includesVideo || writer.canAdd(videoInput)), writer.canAdd(audioInput) else {
            throw CaptureError.couldNotFinishWriter("无法创建合并后的音视频轨道。")
        }
        if includesVideo { writer.add(videoInput) }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw CaptureError.couldNotFinishWriter(
                writer.error?.localizedDescription ?? "合并文件编码器启动失败。"
            )
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw CaptureError.couldNotFinishWriter(
                reader.error?.localizedDescription ?? "无法开始读取录制内容。"
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            if includesVideo {
                async let videoPump: Void = pump(output: videoOutput, input: videoInput,
                                                  reader: reader, writer: writer, label: "画面")
                async let audioPump: Void = pump(output: audioOutput, input: audioInput,
                                                  reader: reader, writer: writer, label: "声音")
                _ = try await (videoPump, audioPump)
            } else {
                try await pump(output: audioOutput, input: audioInput, reader: reader, writer: writer, label: "声音")
            }

            guard reader.status == .completed else {
                throw CaptureError.couldNotFinishWriter(
                    reader.error?.localizedDescription ?? "读取录制内容时中断。"
                )
            }

            writer.endSession(atSourceTime: videoDuration)
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            guard writer.status == .completed else {
                throw CaptureError.couldNotFinishWriter(
                    writer.error?.localizedDescription ?? "合并后的文件没有完成封装。"
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    private static func pump(
        output: AVAssetReaderOutput,
        input: AVAssetWriterInput,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        label: String
    ) async throws {
        while true {
            try Task.checkCancellation()
            if reader.status == .failed {
                throw CaptureError.couldNotFinishWriter(
                    reader.error?.localizedDescription ?? "读取\(label)时中断。"
                )
            }
            if writer.status == .failed || writer.status == .cancelled {
                throw CaptureError.couldNotFinishWriter(
                    writer.error?.localizedDescription ?? "写入\(label)时中断。"
                )
            }

            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return
            }
            guard input.append(sampleBuffer) else {
                throw CaptureError.couldNotFinishWriter(
                    writer.error?.localizedDescription ?? "无法写入\(label)。"
                )
            }
        }
    }

    private static func writeSilence(
        frameCount: Int,
        format: AVAudioFormat,
        to audioFile: AVAudioFile
    ) throws {
        var remainingFrames = frameCount
        while remainingFrames > 0 {
            try Task.checkCancellation()
            let chunkSize = min(8_192, remainingFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunkSize)
            ), let samples = buffer.int16ChannelData?[0] else {
                throw CaptureError.couldNotFinishWriter("无法创建静音缓冲区。")
            }
            buffer.frameLength = AVAudioFrameCount(chunkSize)
            samples.initialize(repeating: 0, count: chunkSize * Int(format.channelCount))
            try audioFile.write(from: buffer)
            remainingFrames -= chunkSize
        }
    }
}
