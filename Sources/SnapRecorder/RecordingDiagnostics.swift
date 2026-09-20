import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

enum RecordingDiagnostics {
    static var isExportPreview: Bool {
        CommandLine.arguments.contains("--preview-export")
            || Bundle.main.object(forInfoDictionaryKey: "SnapRecorderExportPreview") as? Bool == true
    }

    static func run() async throws -> String {
        if CommandLine.arguments.contains("--export-only") { return try await ExportDiagnostics.run() }
        if CommandLine.arguments.contains("--audio-only") { return try await validateVoiceExport() }
        try validateCaptureSizing()
        try validateRegionEffects()
        try validateMouseEffects()
        let cameraReport = try await CameraOverlayDiagnostics.run()
        let portraitReport = try CameraPortraitDiagnostics.run()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapRecorder-self-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let outputSize = CGSize(width: 640, height: 360)
        let sourceSize = CGSize(width: 520, height: 300)
        let writer = try RecordingWriter(
            outputURL: outputURL,
            outputSize: outputSize,
            mode: .browser,
            capturesAudio: false
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

        let qualityReport = try await validateQualityChoiceExport(
            sourceVideoURL: outputURL
        )
        let exportReport = try await ExportDiagnostics.run()
        let voiceReport = try await validateVoiceExport()
        let voiceOnlyReport = try await validateVoiceOnlyExport()
        return "Snap Recorder self-test passed: \(String(format: "%.2f", duration))s, \(Int(naturalSize.width))x\(Int(naturalSize.height)), \(fileSize) bytes; \(qualityReport); \(exportReport); \(voiceReport); \(voiceOnlyReport); \(cameraReport); \(portraitReport)"
    }

    private static func validateQualityChoiceExport(
        sourceVideoURL: URL
    ) async throws -> String {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "SnapRecorder-quality-choice-test-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let maximumSourceURL = directory.appendingPathComponent("maximum-source.mp4")
        let compactSourceURL = directory.appendingPathComponent("compact-source.mp4")
        try fileManager.copyItem(at: sourceVideoURL, to: maximumSourceURL)
        try fileManager.copyItem(at: sourceVideoURL, to: compactSourceURL)

        let service = ScreenCaptureService()
        let maximumDestination = directory.appendingPathComponent("maximum.mp4")
        try service.installPendingRecordingForSelfTest(
            videoURL: maximumSourceURL,
            microphoneURL: nil,
            finalVideoURL: maximumDestination
        )
        let maximumResult = try await service.exportPendingRecording(
            qualityPreset: .maximum,
            selection: RecordingExportSelection(tracks: [.video], arrangement: .merged)
        )

        let compactDestination = directory.appendingPathComponent("compact.mp4")
        let compactResult = try await service.exportPendingRecording(
            qualityPreset: .compact,
            selection: RecordingExportSelection(tracks: [.video], arrangement: .merged),
            name: compactDestination.deletingPathExtension().lastPathComponent
        )

        guard let maximumURL = maximumResult.primaryURL,
              let compactURL = compactResult.primaryURL else {
            throw CaptureError.couldNotFinishWriter("画质选择自检没有生成结果文件。")
        }
        let sourceSignature = try await videoSampleSignature(at: sourceVideoURL)
        let maximumSignature = try await videoSampleSignature(at: maximumURL)
        let compactSignature = try await videoSampleSignature(at: compactURL)
        let sourceAsset = AVURLAsset(url: sourceVideoURL)
        let compactAsset = AVURLAsset(url: compactURL)
        let sourceSize = try await sourceAsset
            .loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
        let compactSize = try await compactAsset
            .loadTracks(withMediaType: .video).first?.load(.naturalSize) ?? .zero
        let compactAttributes = try fileManager.attributesOfItem(atPath: compactURL.path)
        let compactFileSize = (compactAttributes[.size] as? NSNumber)?.intValue ?? 0

        guard maximumResult.urls.count == 1,
              compactResult.urls.count == 1,
              !maximumSignature.isEmpty,
              sourceSignature != compactSignature,
              sourceSize == compactSize,
              compactFileSize > 5_000,
              fileManager.fileExists(atPath: maximumSourceURL.path),
              fileManager.fileExists(atPath: compactSourceURL.path) else {
            throw CaptureError.couldNotFinishWriter(
                "最高画质或小体积导出选择自检异常。"
            )
        }
        try service.discardPendingRecording()
        guard !fileManager.fileExists(atPath: maximumSourceURL.path),
              fileManager.fileExists(atPath: maximumURL.path),
              fileManager.fileExists(atPath: compactURL.path) else {
            throw CaptureError.couldNotFinishWriter("结束导出会话误删了已保存文件。")
        }
        return "repeat export and session cleanup passed"
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
            microphoneOutputURL: voiceURL
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
            microphoneOutputURL: voiceURL
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
        let sourceSignature = try await videoSampleSignature(at: sourceVideoURL)
        let muted = directory.appendingPathComponent("muted.mp4")
        try await RecordingExporter.copyVideoOnly(sourceURL: sourceVideoURL, outputURL: muted)
        guard try await videoSampleSignature(at: muted) == sourceSignature,
              try await AVURLAsset(url: muted).loadTracks(withMediaType: .audio).isEmpty else {
            throw CaptureError.couldNotFinishWriter("去除声音时改写了视频样本。")
        }

        let service = ScreenCaptureService()
        try service.installPendingRecordingForSelfTest(
            videoURL: sourceVideoURL,
            microphoneURL: sourceVoiceURL,
            finalVideoURL: desiredVideoURL
        )
        let all: Set<RecordingTrack> = [.video, .systemAudio, .voice]
        // Occupy one member of the three-file batch; every output must share its new suffix.
        let occupied = TimeFormatting.separateVideoOutputURL(matching: desiredVideoURL)
        try Data().write(to: occupied)
        let result = try await service.exportPendingRecording(
            qualityPreset: .maximum,
            selection: RecordingExportSelection(tracks: all, arrangement: .separate)
        )
        let prefixes = ["Snap 视频 ", "Snap 电脑声音 ", "Snap 人声 "]
        guard result.urls.count == 3,
              zip(result.urls, prefixes).allSatisfy({ $0.lastPathComponent.hasPrefix($1) && $0.lastPathComponent.contains(" (2)") }),
              try await AVURLAsset(url: result.urls[0]).loadTracks(withMediaType: .audio).isEmpty,
              try ExportPlanning.fileBytes(occupied) == 0 else {
            throw CaptureError.couldNotFinishWriter("全部分轨、视频无声或统一重名后缀异常。")
        }
        try await ExportDiagnostics.validateToneIsolation(video: result.urls[1], voice: result.urls[2])
        let sourceDuration = try await AVURLAsset(url: sourceVideoURL).load(.duration).seconds
        var allOutputs = result.urls
        // Every nonempty content subset, with each valid arrangement, is tested against real decoded media.
        for bits in 1...7 {
            let tracks = Set(RecordingTrack.allCases.enumerated().compactMap { bits & (1 << $0.offset) != 0 ? $0.element : nil })
            for arrangement in ExportArrangement.allCases {
                let selection = RecordingExportSelection(tracks: tracks, arrangement: arrangement)
                let exported = try await service.exportPendingRecording(
                    qualityPreset: .custom, selection: selection,
                    name: "组合-\(bits)-\(arrangement.rawValue)",
                    // Audio-only must ignore an irrelevant, invalid video budget.
                    customMegabytes: tracks.contains(.video) ? 0.3 : .nan
                )
                guard exported.urls.count == selection.files.count else {
                    throw CaptureError.couldNotFinishWriter("输出文件数量错误。")
                }
                for (url, kind) in zip(exported.urls, selection.files) {
                    let asset = AVURLAsset(url: url)
                    let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
                    let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
                    let duration = try await asset.load(.duration).seconds
                    var expectedSystem = false, expectedVoice = false
                    switch kind {
                    case .video, .mergedVideo:
                        expectedSystem = selection.includesSystemInVideo
                        expectedVoice = selection.includesVoiceInVideo
                        guard hasVideo, try ExportPlanning.fileBytes(url) <= 300_000 else {
                            throw CaptureError.couldNotFinishWriter("视频缺失或超出上限。")
                        }
                    case .systemAudio: expectedSystem = true
                    case .voice: expectedVoice = true
                    case .mixedAudio: expectedSystem = true; expectedVoice = true
                    }
                    guard abs(duration - sourceDuration) <= 0.04,
                          hasAudio == (expectedSystem || expectedVoice),
                          hasVideo == (kind == .video || kind == .mergedVideo) else {
                        throw CaptureError.couldNotFinishWriter("内容轨道或时长错误：\(url.lastPathComponent)，\(duration)/\(sourceDuration)s，video=\(hasVideo)，audio=\(hasAudio)。")
                    }
                    if hasAudio {
                        try await ExportDiagnostics.validateTones(url: url, system: expectedSystem, voice: expectedVoice)
                    }
                }
                allOutputs += exported.urls
            }
        }
        guard fileManager.fileExists(atPath: sourceVideoURL.path), fileManager.fileExists(atPath: sourceVoiceURL.path) else {
            throw CaptureError.couldNotFinishWriter("重复导出丢失原片。")
        }
        try service.discardPendingRecording()
        guard allOutputs.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            throw CaptureError.couldNotFinishWriter("清理损坏了已存文件。")
        }
        return "all content subsets and arrangements, isolation, audio-only mix, collision and repeated export passed"
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

            guard isEven(layout.outputSize.width),
                  isEven(layout.outputSize.height),
                  isEven(layout.streamSize.width),
                  isEven(layout.streamSize.height),
                  layout.outputSize.width <= CaptureSizing.maximumHighDefinitionOutputSize.width,
                  layout.outputSize.height <= CaptureSizing.maximumHighDefinitionOutputSize.height,
                  layout.streamSize.width <= source.width,
                  layout.streamSize.height <= source.height,
                  relativeDifference(outputRatio, sourceRatio) < 0.005,
                  layout.streamSize == layout.outputSize,
                  layout.contentRect == CGRect(origin: .zero, size: layout.outputSize) else {
                throw CaptureError.couldNotFinishWriter(
                    "浏览器布局自检异常（源 \(source)，输出 \(layout.outputSize)，采集 \(layout.streamSize)）。"
                )
            }
        }

        let nativeBrowserLayout = CaptureSizing.browserLayout(
            source: CGSize(width: 2_882, height: 1_898)
        )
        guard nativeBrowserLayout.outputSize == CGSize(width: 2_882, height: 1_898),
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
        guard displaySize == CGSize(width: 3_024, height: 1_964) else {
            throw CaptureError.couldNotFinishWriter("高清输出尺寸自检异常。")
        }

        for aspectRatio in CaptureAspectRatio.allCases {
            guard let fixedValue = aspectRatio.fixedValue else { continue }
            let source = CGSize(width: 1_200, height: 1_200 / fixedValue)
            let output = CaptureSizing.regionOutputSize(source: source)
            guard isEven(output.width),
                  isEven(output.height),
                  relativeDifference(output.width / output.height, fixedValue) < 0.01 else {
                throw CaptureError.couldNotFinishWriter(
                    "局部录制比例自检异常（\(aspectRatio.title)，输出 \(output)）。"
                )
            }
        }
    }

    private static func validateRegionEffects() throws {
        let size = CGSize(width: 240, height: 160)
        let source = try makeSolidPixelBuffer(
            size: size,
            color: CIColor(red: 0.82, green: 0.22, blue: 0.08)
        )
        let focusRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        let roundedDestination = try makeSolidPixelBuffer(size: size, color: .black)
        FrameCompositor(
            mode: .region,
            outputSize: size,
            focusMask: CaptureFocusMask(
                normalizedRect: focusRect,
                cornerStyle: .rounded
            )
        ).render(source: source, into: roundedDestination)

        let squareDestination = try makeSolidPixelBuffer(size: size, color: .black)
        FrameCompositor(
            mode: .region,
            outputSize: size,
            focusMask: CaptureFocusMask(
                normalizedRect: focusRect,
                cornerStyle: .square
            )
        ).render(source: source, into: squareDestination)

        let vignetteDestination = try makeSolidPixelBuffer(size: size, color: .black)
        FrameCompositor(
            mode: .region,
            outputSize: size,
            captureCornerStyle: .rounded,
            appliesSoftCornerVignette: true
        ).render(source: source, into: vignetteDestination)

        let center = pixel(in: roundedDestination, x: 120, y: 80)
        let outside = pixel(in: roundedDestination, x: 18, y: 80)
        let roundedCorner = pixel(in: roundedDestination, x: 62, y: 42)
        let squareCorner = pixel(in: squareDestination, x: 62, y: 42)
        let vignetteCenter = pixel(in: vignetteDestination, x: 120, y: 80)
        let vignetteCorner = pixel(in: vignetteDestination, x: 0, y: 0)

        guard center.red > center.green * 2,
              channelSpread(outside) < 10,
              outside.brightness < center.red * 0.5,
              outside.brightness > 20,
              channelSpread(roundedCorner) < 16,
              squareCorner.red > squareCorner.green * 2,
              vignetteCorner.brightness < vignetteCenter.brightness * 0.8 else {
            throw CaptureError.couldNotFinishWriter(
                "局部录制效果自检异常（中心 \(center)，外部 \(outside)，圆角 \(roundedCorner)，方角 \(squareCorner)，暗角 \(vignetteCorner)/\(vignetteCenter)）。"
            )
        }
    }

    private static func validateMouseEffects() throws {
        let size = CGSize(width: 240, height: 160)
        let captureRect = CGRect(x: 320, y: 180, width: 1_200, height: 800)
        guard MouseEffectTracker.normalizedPosition(
            for: CGPoint(x: 620, y: 380),
            in: captureRect
        ) == CGPoint(x: 0.25, y: 0.25),
              MouseEffectTracker.normalizedPosition(
                  for: CGPoint(x: 100, y: 100),
                  in: captureRect
              ) == nil else {
            throw CaptureError.couldNotFinishWriter("鼠标坐标映射自检异常。")
        }

        let source = try makeSolidPixelBuffer(
            size: size,
            color: CIColor(red: 0.04, green: 0.05, blue: 0.08)
        )
        let baseDestination = try makeSolidPixelBuffer(size: size, color: .black)
        let cursorDestination = try makeSolidPixelBuffer(size: size, color: .black)
        let clickDestination = try makeSolidPixelBuffer(size: size, color: .black)
        let compositor = FrameCompositor(mode: .display, outputSize: size)

        compositor.render(source: source, into: baseDestination)
        compositor.render(
            source: source,
            into: cursorDestination,
            mouseEffect: MouseEffectSnapshot(
                normalizedCursorPosition: CGPoint(x: 0.5, y: 0.5),
                clickEffect: nil
            )
        )
        compositor.render(
            source: source,
            into: clickDestination,
            mouseEffect: MouseEffectSnapshot(
                normalizedCursorPosition: nil,
                clickEffect: MouseClickEffect(
                    normalizedPosition: CGPoint(x: 0.5, y: 0.5),
                    progress: 0.5
                )
            )
        )

        let baseCenter = pixel(in: baseDestination, x: 120, y: 80)
        let cursorCenter = pixel(in: cursorDestination, x: 120, y: 80)
        let baseRing = pixel(in: baseDestination, x: 141, y: 80)
        let clickRing = pixel(in: clickDestination, x: 141, y: 80)

        guard cursorCenter.brightness > baseCenter.brightness * 4,
              clickRing.red > baseRing.red * 1.5,
              clickRing.red > clickRing.green else {
            throw CaptureError.couldNotFinishWriter(
                "鼠标光点效果自检异常（中心 \(cursorCenter)/\(baseCenter)，点击 \(clickRing)/\(baseRing)）。"
            )
        }
    }

    private struct PixelSample {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        var brightness: CGFloat { (red + green + blue) / 3 }
    }

    private static func channelSpread(_ pixel: PixelSample) -> CGFloat {
        max(pixel.red, max(pixel.green, pixel.blue))
            - min(pixel.red, min(pixel.green, pixel.blue))
    }

    private static func makeSolidPixelBuffer(
        size: CGSize,
        color: CIColor
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CaptureError.couldNotStartWriter(
                "自检无法创建局部录制画面缓冲区（状态 \(status)）。"
            )
        }
        CIContext(options: [.useSoftwareRenderer: false]).render(
            CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size)),
            to: pixelBuffer,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return pixelBuffer
    }

    private static func pixel(in buffer: CVPixelBuffer, x: Int, y: Int) -> PixelSample {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return PixelSample(red: 0, green: 0, blue: 0)
        }
        let safeX = min(max(x, 0), CVPixelBufferGetWidth(buffer) - 1)
        let safeY = min(max(y, 0), CVPixelBufferGetHeight(buffer) - 1)
        let offset = safeY * CVPixelBufferGetBytesPerRow(buffer) + safeX * 4
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return PixelSample(
            red: CGFloat(bytes[offset + 2]),
            green: CGFloat(bytes[offset + 1]),
            blue: CGFloat(bytes[offset])
        )
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
