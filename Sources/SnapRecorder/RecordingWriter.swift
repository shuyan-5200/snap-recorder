import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class RecordingWriter {
    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let microphoneAssetWriter: AVAssetWriter?
    private let microphoneInput: AVAssetWriterInput?
    private let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let compositor: FrameCompositor

    private var sessionStarted = false
    private var sessionStartTime = CMTime.invalid
    private var accumulatedPauseTime = CMTime.zero
    private var pauseBeganAt = CMTime.invalid
    private var isPaused = false
    private var lastVideoTime = CMTime.invalid
    private var microphoneSessionStarted = false
    private var hasMicrophoneSamples = false
    private var pendingError: Error?

    init(
        outputURL: URL,
        outputSize: CGSize,
        mode: CaptureMode,
        capturesAudio: Bool,
        microphoneOutputURL: URL? = nil,
        wallpaperURL: URL?
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        assetWriter.shouldOptimizeForNetworkUse = true

        let bitrate = RecordingQuality.videoBitrate(for: outputSize)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: 120,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: false
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attributes
        )

        if capturesAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            audioInput = input
        } else {
            audioInput = nil
        }

        compositor = FrameCompositor(
            mode: mode,
            outputSize: outputSize,
            wallpaperURL: wallpaperURL
        )

        guard assetWriter.canAdd(videoInput) else {
            throw CaptureError.couldNotStartWriter("当前设备无法创建视频轨道。")
        }
        assetWriter.add(videoInput)

        if let audioInput {
            guard assetWriter.canAdd(audioInput) else {
                throw CaptureError.couldNotStartWriter("当前设备无法创建声音轨道。")
            }
            assetWriter.add(audioInput)
        }

        guard assetWriter.startWriting() else {
            throw CaptureError.couldNotStartWriter(
                assetWriter.error?.localizedDescription ?? "编码器启动失败。"
            )
        }

        do {
            if let microphoneOutputURL {
                try? FileManager.default.removeItem(at: microphoneOutputURL)
                let writer = try AVAssetWriter(outputURL: microphoneOutputURL, fileType: .m4a)
                writer.shouldOptimizeForNetworkUse = true
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 192_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else {
                    throw CaptureError.couldNotStartWriter("当前设备无法创建人声音轨。")
                }
                writer.add(input)
                guard writer.startWriting() else {
                    throw CaptureError.couldNotStartWriter(
                        writer.error?.localizedDescription ?? "人声编码器启动失败。"
                    )
                }
                microphoneAssetWriter = writer
                microphoneInput = input
            } else {
                microphoneAssetWriter = nil
                microphoneInput = nil
            }
        } catch {
            assetWriter.cancelWriting()
            throw error
        }
    }

    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard !isPaused,
              pendingError == nil,
              assetWriter.status == .writing,
              CMSampleBufferDataIsReady(sampleBuffer),
              let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              videoInput.isReadyForMoreMediaData else { return false }

        var presentationTime = adjustedTime(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        guard presentationTime.isValid else { return false }

        if lastVideoTime.isValid, CMTimeCompare(presentationTime, lastVideoTime) <= 0 {
            presentationTime = CMTimeAdd(lastVideoTime, CMTime(value: 1, timescale: 600))
        }

        if !sessionStarted {
            assetWriter.startSession(atSourceTime: presentationTime)
            sessionStarted = true
            sessionStartTime = presentationTime
            if let microphoneAssetWriter {
                microphoneAssetWriter.startSession(atSourceTime: presentationTime)
                microphoneSessionStarted = true
            }
        }

        guard let pool = pixelBufferAdaptor.pixelBufferPool else {
            pendingError = CaptureError.couldNotStartWriter("无法分配高清视频缓冲区。")
            return false
        }

        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            return false
        }

        compositor.render(source: sourceBuffer, into: destination)
        if pixelBufferAdaptor.append(destination, withPresentationTime: presentationTime) {
            lastVideoTime = presentationTime
            return true
        } else if assetWriter.status == .failed {
            pendingError = assetWriter.error
                ?? CaptureError.couldNotFinishWriter("视频编码中断。")
        }
        return false
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isPaused,
              pendingError == nil,
              sessionStarted,
              assetWriter.status == .writing,
              let audioInput,
              audioInput.isReadyForMoreMediaData else { return }

        let offset = effectivePauseTime(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard let adjusted = copy(sampleBuffer: sampleBuffer, subtracting: offset) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(adjusted)
        guard presentationTime.isValid,
              CMTimeCompare(presentationTime, sessionStartTime) >= 0 else { return }

        if !audioInput.append(adjusted), assetWriter.status == .failed {
            pendingError = assetWriter.error
                ?? CaptureError.couldNotFinishWriter("声音编码中断。")
        }
    }

    @discardableResult
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard !isPaused,
              pendingError == nil,
              sessionStarted,
              microphoneSessionStarted,
              let microphoneAssetWriter,
              microphoneAssetWriter.status == .writing,
              let microphoneInput,
              microphoneInput.isReadyForMoreMediaData else { return false }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let offset = effectivePauseTime(at: sourceTime)
        guard let adjusted = copy(sampleBuffer: sampleBuffer, subtracting: offset) else {
            return false
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(adjusted)
        guard presentationTime.isValid,
              CMTimeCompare(presentationTime, sessionStartTime) >= 0 else { return false }

        if microphoneInput.append(adjusted) {
            hasMicrophoneSamples = true
            return true
        }
        if microphoneAssetWriter.status == .failed {
            pendingError = microphoneAssetWriter.error
                ?? CaptureError.couldNotFinishWriter("人声编码中断。")
        }
        return false
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pauseBeganAt = hostTimeNow()
    }

    func resume() {
        guard isPaused else { return }
        let now = hostTimeNow()
        if pauseBeganAt.isValid {
            accumulatedPauseTime = CMTimeAdd(
                accumulatedPauseTime,
                CMTimeSubtract(now, pauseBeganAt)
            )
        }
        pauseBeganAt = .invalid
        isPaused = false
    }

    func finish() async throws {
        guard sessionStarted else {
            assetWriter.cancelWriting()
            throw CaptureError.couldNotFinishWriter("没有捕获到可写入的画面。")
        }

        let now = hostTimeNow()
        let endTime = CMTimeSubtract(now, effectivePauseTime(at: now))
        if lastVideoTime.isValid, CMTimeCompare(endTime, lastVideoTime) > 0 {
            assetWriter.endSession(atSourceTime: endTime)
        }
        if let microphoneAssetWriter, microphoneSessionStarted {
            microphoneAssetWriter.endSession(atSourceTime: endTime)
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        microphoneInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            assetWriter.finishWriting {
                continuation.resume()
            }
        }

        if let microphoneAssetWriter {
            guard hasMicrophoneSamples else {
                microphoneAssetWriter.cancelWriting()
                throw CaptureError.noMicrophoneSamples
            }
            await withCheckedContinuation { continuation in
                microphoneAssetWriter.finishWriting {
                    continuation.resume()
                }
            }
        }

        if let pendingError {
            throw pendingError
        }
        guard assetWriter.status == .completed else {
            throw CaptureError.couldNotFinishWriter(
                assetWriter.error?.localizedDescription ?? "编码器没有完成视频封装。"
            )
        }
        if let microphoneAssetWriter,
           microphoneAssetWriter.status != .completed {
            throw CaptureError.couldNotFinishWriter(
                microphoneAssetWriter.error?.localizedDescription ?? "人声文件没有完成封装。"
            )
        }
    }

    func cancel() {
        assetWriter.cancelWriting()
        microphoneAssetWriter?.cancelWriting()
    }

    private func adjustedTime(_ sourceTime: CMTime) -> CMTime {
        guard sourceTime.isValid else { return sourceTime }
        return CMTimeSubtract(sourceTime, effectivePauseTime(at: sourceTime))
    }

    private func effectivePauseTime(at time: CMTime) -> CMTime {
        guard isPaused, pauseBeganAt.isValid, time.isValid else {
            return accumulatedPauseTime
        }
        return CMTimeAdd(
            accumulatedPauseTime,
            CMTimeMaximum(.zero, CMTimeSubtract(time, pauseBeganAt))
        )
    }

    private func hostTimeNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private func copy(
        sampleBuffer: CMSampleBuffer,
        subtracting offset: CMTime
    ) -> CMSampleBuffer? {
        guard CMTimeCompare(offset, .zero) > 0 else { return sampleBuffer }

        var needed = 0
        let firstStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &needed
        )
        guard firstStatus == noErr, needed > 0 else { return nil }

        var timings = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: needed
        )
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: needed,
            arrayToFill: &timings,
            entriesNeededOut: &needed
        )
        guard timingStatus == noErr else { return nil }

        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeSubtract(
                    timings[index].presentationTimeStamp,
                    offset
                )
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(
                    timings[index].decodeTimeStamp,
                    offset
                )
            }
        }

        var output: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleBufferOut: &output
        )
        return copyStatus == noErr ? output : nil
    }
}
