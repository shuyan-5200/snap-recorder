import AVFoundation
import CoreMedia
import Foundation

enum RecordingExporter {
    static func alignVoice(
        microphoneURL: URL,
        matchingVideoURL: URL,
        outputURL: URL
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let videoAsset = AVURLAsset(url: matchingVideoURL)
        let targetDuration = try await videoAsset.load(.duration)
        let microphoneAsset = AVURLAsset(url: microphoneURL)
        guard targetDuration.isValid,
              targetDuration.isNumeric,
              CMTimeCompare(targetDuration, .zero) > 0,
              let microphoneTrack = try await microphoneAsset
                .loadTracks(withMediaType: .audio).first else {
            throw CaptureError.couldNotFinishWriter("无法读取待对齐的人声文件。")
        }

        let reader = try AVAssetReader(asset: microphoneAsset)
        reader.timeRange = CMTimeRange(start: .zero, duration: targetDuration)
        let output = AVAssetReaderTrackOutput(
            track: microphoneTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CaptureError.couldNotFinishWriter("无法解码人声音轨。")
        }
        reader.add(output)

        let sampleRate = 48_000.0
        let targetFrameCount = max(1, Int((targetDuration.seconds * sampleRate).rounded()))
        guard reader.startReading() else {
            throw CaptureError.couldNotFinishWriter(
                reader.error?.localizedDescription ?? "无法开始读取人声。"
            )
        }

        do {
            try autoreleasepool {
                let audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 192_000,
                        AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
                    ],
                    commonFormat: .pcmFormatInt16,
                    interleaved: true
                )
                let processingFormat = audioFile.processingFormat
                var writtenFrames = 0

                while let sampleBuffer = output.copyNextSampleBuffer() {
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
                        throw CaptureError.couldNotFinishWriter("无法创建人声 PCM 缓冲区。")
                    }
                    pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
                    let copyStatus = CMBlockBufferCopyDataBytes(
                        dataBuffer,
                        atOffset: sourceOffset * MemoryLayout<Int16>.size,
                        dataLength: frameCount * MemoryLayout<Int16>.size,
                        destination: destination
                    )
                    guard copyStatus == kCMBlockBufferNoErr else {
                        throw CaptureError.couldNotFinishWriter("无法读取人声 PCM 数据。")
                    }
                    try audioFile.write(from: pcmBuffer)
                    writtenFrames += frameCount
                }

                guard reader.status == .completed else {
                    throw CaptureError.couldNotFinishWriter(
                        reader.error?.localizedDescription ?? "读取人声时中断。"
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
                    throw CaptureError.couldNotFinishWriter("人声帧数没有与视频对齐。")
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
        outputURL: URL
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

        if let sourceSystemTrack = try await videoAsset.loadTracks(withMediaType: .audio).first,
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
        reader.add(videoOutput)

        let audioOutput = AVAssetReaderAudioMixOutput(
            audioTracks: compositionAudioTracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
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
                AVEncoderBitRateKey: 256_000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
        )
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw CaptureError.couldNotFinishWriter("无法创建合并后的音视频轨道。")
        }
        writer.add(videoInput)
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
            async let videoPump: Void = pump(
                output: videoOutput,
                input: videoInput,
                reader: reader,
                writer: writer,
                label: "画面"
            )
            async let audioPump: Void = pump(
                output: audioOutput,
                input: audioInput,
                reader: reader,
                writer: writer,
                label: "声音"
            )
            _ = try await (videoPump, audioPump)

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
            if reader.status == .failed {
                throw CaptureError.couldNotFinishWriter(
                    reader.error?.localizedDescription ?? "读取\(label)时中断。"
                )
            }
            if writer.status == .failed {
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
            let chunkSize = min(8_192, remainingFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunkSize)
            ), let samples = buffer.int16ChannelData?[0] else {
                throw CaptureError.couldNotFinishWriter("无法创建静音缓冲区。")
            }
            buffer.frameLength = AVAudioFrameCount(chunkSize)
            samples.initialize(repeating: 0, count: chunkSize)
            try audioFile.write(from: buffer)
            remainingFrames -= chunkSize
        }
    }
}
