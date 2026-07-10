import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

final class ScreenCaptureService: NSObject, @unchecked Sendable {
    var unexpectedStopHandler: ((Error) -> Void)?

    private let sampleQueue = DispatchQueue(
        label: "io.github.shuyan-5200.SnapRecorder.capture-samples",
        qos: .userInteractive
    )
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var finalOutputURL: URL?
    private var temporaryOutputURL: URL?
    private var temporaryMicrophoneURL: URL?
    private var pendingRecording: PendingRecording?
    private(set) var recoveryURLs: [URL] = []
    private var isStopping = false
    private let lifecycleLock = NSLock()
    private var acceptingSamples = false
    private let firstFrameLock = NSLock()
    private var firstFrameContinuation: CheckedContinuation<Void, Error>?
    private var hasReceivedFirstFrame = false
    private var requiresMicrophoneSample = false
    private var hasReceivedMicrophoneSample = false
    private var firstFrameGeneration = UUID()

    private struct PendingRecording {
        let videoURL: URL
        let microphoneURL: URL?
        let finalVideoURL: URL
    }

    private struct VoiceExportDestinations {
        let combinedVideoURL: URL
        let separateVideoURL: URL
        let voiceURL: URL

        func selectedURLs(for modes: Set<VoiceExportMode>) -> [URL] {
            var urls: [URL] = []
            if modes.contains(.combined) {
                urls.append(combinedVideoURL)
            }
            if modes.contains(.separate) {
                urls.append(separateVideoURL)
                urls.append(voiceURL)
            }
            return urls
        }
    }

    var hasRetryableAutomaticSave: Bool {
        guard let pendingRecording else { return false }
        return pendingRecording.microphoneURL == nil
    }

    func installPendingRecordingForSelfTest(
        videoURL: URL,
        microphoneURL: URL,
        finalVideoURL: URL
    ) throws {
        guard CommandLine.arguments.contains("--self-test"), pendingRecording == nil else {
            throw CaptureError.couldNotStartWriter("自检导出状态无法初始化。")
        }
        pendingRecording = PendingRecording(
            videoURL: videoURL,
            microphoneURL: microphoneURL,
            finalVideoURL: finalVideoURL
        )
        recoveryURLs = [videoURL, microphoneURL]
    }

    func browserWindows() async throws -> [BrowserWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )

        return content.windows
            .filter(Self.isBrowserWindow)
            .map { window in
                BrowserWindowInfo(
                    id: window.windowID,
                    processID: window.owningApplication?.processID ?? 0,
                    applicationName: window.owningApplication?.applicationName ?? "浏览器",
                    bundleIdentifier: window.owningApplication?.bundleIdentifier ?? "",
                    title: window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    isOnScreen: window.isOnScreen,
                    size: window.frame.size
                )
            }
            .sorted { lhs, rhs in
                if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
                if lhs.applicationName != rhs.applicationName {
                    return lhs.applicationName.localizedStandardCompare(rhs.applicationName) == .orderedAscending
                }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    func start(_ request: CaptureRequest) async throws {
        guard pendingRecording == nil else {
            throw CaptureError.couldNotStartWriter("请先保存上一段录制。")
        }
        recoveryURLs = []
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionRequired
        }

        if request.capturesMicrophone {
            guard #available(macOS 15.0, *) else {
                throw CaptureError.microphoneRequiresNewerSystem
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw CaptureError.microphonePermissionRequired
            }
            guard AVCaptureDevice.default(for: .audio) != nil else {
                throw CaptureError.microphoneUnavailable
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let filter: SCContentFilter
        let streamSize: CGSize
        let outputSize: CGSize

        switch request.mode {
        case .browser:
            guard let windowID = request.browserWindowID else {
                throw CaptureError.noBrowserWindow
            }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.browserWindowUnavailable
            }

            filter = SCContentFilter(desktopIndependentWindow: window)
            let sourcePixels = CGSize(
                width: max(2, filter.contentRect.width * CGFloat(filter.pointPixelScale)),
                height: max(2, filter.contentRect.height * CGFloat(filter.pointPixelScale))
            )
            let layout = CaptureSizing.browserLayout(source: sourcePixels)
            streamSize = layout.streamSize
            outputSize = layout.outputSize

        case .display:
            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                ?? content.displays.first else {
                throw CaptureError.noDisplay
            }

            let ownApplication = content.applications.first {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplication.map { [$0] } ?? [],
                exceptingWindows: []
            )

            let sourcePixels = CGSize(
                width: max(2, filter.contentRect.width * CGFloat(filter.pointPixelScale)),
                height: max(2, filter.contentRect.height * CGFloat(filter.pointPixelScale))
            )
            outputSize = CaptureSizing.fit(
                source: sourcePixels,
                inside: CaptureSizing.maximumHighDefinitionOutputSize,
                allowUpscale: false
            )
            streamSize = outputSize
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(streamSize.width)
        configuration.height = Int(streamSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = true
        configuration.capturesAudio = request.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.colorSpaceName = CGColorSpace.sRGB as CFString
        configuration.shouldBeOpaque = true
        configuration.captureResolution = .best

        if #available(macOS 15.0, *), request.capturesMicrophone {
            configuration.captureMicrophone = true
        }

        if request.mode == .browser {
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
        }

        let temporaryURL = try makeTemporaryOutputURL(pathExtension: "mp4")
        let microphoneURL = request.capturesMicrophone
            ? try makeTemporaryOutputURL(pathExtension: "m4a")
            : nil
        var createdWriter: RecordingWriter?
        var createdStream: SCStream?
        do {
            let writer = try RecordingWriter(
                outputURL: temporaryURL,
                outputSize: outputSize,
                mode: request.mode,
                capturesAudio: request.capturesSystemAudio,
                microphoneOutputURL: microphoneURL,
                wallpaperURL: request.wallpaperURL
            )
            createdWriter = writer

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            createdStream = stream
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if request.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if #available(macOS 15.0, *), request.capturesMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }

            self.stream = stream
            self.writer = writer
            finalOutputURL = request.outputURL
            temporaryOutputURL = temporaryURL
            temporaryMicrophoneURL = microphoneURL
            isStopping = false
            setAcceptingSamples(true)
            prepareFirstFrameWait(requiresMicrophone: request.capturesMicrophone)

            try await stream.startCapture()
            try await waitForFirstFrame()
        } catch {
            isStopping = true
            setAcceptingSamples(false)
            if let createdStream {
                try? await createdStream.stopCapture()
            }
            await drainSampleQueue()
            createdWriter?.cancel()
            self.stream = nil
            self.writer = nil
            finalOutputURL = nil
            temporaryOutputURL = nil
            temporaryMicrophoneURL = nil
            isStopping = false
            try? FileManager.default.removeItem(at: temporaryURL)
            if let microphoneURL {
                try? FileManager.default.removeItem(at: microphoneURL)
            }
            throw error
        }
    }

    func pause() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                self?.writer?.pause()
                continuation.resume()
            }
        }
    }

    func resume() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                self?.writer?.resume()
                continuation.resume()
            }
        }
    }

    func stop() async throws -> CaptureStopOutcome {
        isStopping = true
        setAcceptingSamples(false)
        if let stream {
            try? await stream.stopCapture()
        }

        await drainSampleQueue()

        guard let writer,
              let temporaryOutputURL,
              let finalOutputURL else {
            reset()
            throw CaptureError.couldNotFinishWriter("录制器尚未启动。")
        }

        var writerFinished = false
        do {
            try await writer.finish()
            writerFinished = true
            if let temporaryMicrophoneURL {
                let pending = PendingRecording(
                    videoURL: temporaryOutputURL,
                    microphoneURL: temporaryMicrophoneURL,
                    finalVideoURL: finalOutputURL
                )
                reset(keepTemporaryFile: true)
                pendingRecording = pending
                return .awaitingExportChoice
            }

            let availableOutputURL = availableOutputURL(startingAt: finalOutputURL)
            try moveCompletedRecording(from: temporaryOutputURL, to: availableOutputURL)
            reset()
            recoveryURLs = []
            return .exported(RecordingResult(urls: [availableOutputURL]))
        } catch {
            let recoverableURLs = [temporaryOutputURL, temporaryMicrophoneURL]
                .compactMap { $0 }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if writerFinished, temporaryMicrophoneURL == nil {
                let pending = PendingRecording(
                    videoURL: temporaryOutputURL,
                    microphoneURL: nil,
                    finalVideoURL: finalOutputURL
                )
                reset(keepTemporaryFile: true)
                pendingRecording = pending
            } else {
                reset(keepTemporaryFile: true)
            }
            recoveryURLs = recoverableURLs
            throw error
        }
    }

    func retryPendingAutomaticSave() throws -> RecordingResult {
        guard let pendingRecording, pendingRecording.microphoneURL == nil else {
            throw CaptureError.couldNotFinishWriter("没有可重试保存的录制内容。")
        }
        let outputURL = availableOutputURL(startingAt: pendingRecording.finalVideoURL)
        try moveCompletedRecording(from: pendingRecording.videoURL, to: outputURL)
        self.pendingRecording = nil
        recoveryURLs = []
        return RecordingResult(urls: [outputURL])
    }

    func exportPendingRecording(_ modes: Set<VoiceExportMode>) async throws -> RecordingResult {
        guard let pendingRecording,
              let microphoneURL = pendingRecording.microphoneURL else {
            throw CaptureError.couldNotFinishWriter("没有等待导出的录制内容。")
        }
        guard !modes.isEmpty else {
            throw CaptureError.couldNotFinishWriter("请至少选择一种导出方式。")
        }
        let destinations = availableVoiceExportDestinations(
            startingAt: pendingRecording.finalVideoURL,
            modes: modes
        )
        var temporaryCombinedURL: URL?
        var temporarySeparateVideoURL: URL?
        var temporaryAlignedVoiceURL: URL?
        var committedURLs: [URL] = []

        do {
            try ensureExportDiskSpace(for: pendingRecording, modes: modes)

            if modes.contains(.combined) {
                let combinedURL = try makeTemporaryOutputURL(pathExtension: "mp4")
                temporaryCombinedURL = combinedURL
                try await RecordingExporter.combine(
                    videoURL: pendingRecording.videoURL,
                    microphoneURL: microphoneURL,
                    outputURL: combinedURL
                )
            }

            if modes.contains(.separate) {
                let separateVideoURL = try makeTemporaryOutputURL(pathExtension: "mp4")
                temporarySeparateVideoURL = separateVideoURL
                try copyCompletedRecording(
                    from: pendingRecording.videoURL,
                    to: separateVideoURL
                )

                let alignedVoiceURL = try makeTemporaryOutputURL(pathExtension: "m4a")
                temporaryAlignedVoiceURL = alignedVoiceURL
                try await RecordingExporter.alignVoice(
                    microphoneURL: microphoneURL,
                    matchingVideoURL: pendingRecording.videoURL,
                    outputURL: alignedVoiceURL
                )
            }

            if let temporaryCombinedURL {
                try moveCompletedRecording(
                    from: temporaryCombinedURL,
                    to: destinations.combinedVideoURL
                )
                committedURLs.append(destinations.combinedVideoURL)
            }

            if let temporarySeparateVideoURL, let temporaryAlignedVoiceURL {
                try moveCompletedRecording(
                    from: temporarySeparateVideoURL,
                    to: destinations.separateVideoURL
                )
                committedURLs.append(destinations.separateVideoURL)
                try moveCompletedRecording(
                    from: temporaryAlignedVoiceURL,
                    to: destinations.voiceURL
                )
                committedURLs.append(destinations.voiceURL)
            }

            try? FileManager.default.removeItem(at: pendingRecording.videoURL)
            try? FileManager.default.removeItem(at: microphoneURL)
            self.pendingRecording = nil
            recoveryURLs = []
            return RecordingResult(urls: destinations.selectedURLs(for: modes))
        } catch {
            if let temporaryCombinedURL {
                try? FileManager.default.removeItem(at: temporaryCombinedURL)
            }
            if let temporarySeparateVideoURL {
                try? FileManager.default.removeItem(at: temporarySeparateVideoURL)
            }
            if let temporaryAlignedVoiceURL {
                try? FileManager.default.removeItem(at: temporaryAlignedVoiceURL)
            }
            for url in committedURLs {
                try? FileManager.default.removeItem(at: url)
            }
            recoveryURLs = [pendingRecording.videoURL, microphoneURL]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            throw error
        }
    }

    private func reset(keepTemporaryFile: Bool = false) {
        if !keepTemporaryFile, let temporaryOutputURL {
            try? FileManager.default.removeItem(at: temporaryOutputURL)
        }
        if !keepTemporaryFile, let temporaryMicrophoneURL {
            try? FileManager.default.removeItem(at: temporaryMicrophoneURL)
        }
        stream = nil
        writer = nil
        finalOutputURL = nil
        temporaryOutputURL = nil
        temporaryMicrophoneURL = nil
        isStopping = false
        setAcceptingSamples(false)
        clearFirstFrameWait()
    }

    private func makeTemporaryOutputURL(pathExtension: String) throws -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("SnapRecorder", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("\(UUID().uuidString).\(pathExtension)")
    }

    private func moveCompletedRecording(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            throw CaptureError.couldNotFinishWriter("目标文件已存在，请重试导出。")
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func copyCompletedRecording(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            throw CaptureError.couldNotFinishWriter("目标文件已存在，请重试导出。")
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func availableVoiceExportDestinations(
        startingAt desiredURL: URL,
        modes: Set<VoiceExportMode>
    ) -> VoiceExportDestinations {
        let fileManager = FileManager.default
        let directory = desiredURL.deletingLastPathComponent()
        let initialStem = desiredURL.deletingPathExtension().lastPathComponent
        var candidate = desiredURL
        var index = 2

        while true {
            let separateVideoURL = TimeFormatting.separateVideoOutputURL(
                matching: candidate
            )
            let destinations = VoiceExportDestinations(
                combinedVideoURL: candidate,
                separateVideoURL: separateVideoURL,
                voiceURL: TimeFormatting.voiceOutputURL(matching: separateVideoURL)
            )
            let hasConflict = destinations.selectedURLs(for: modes).contains {
                fileManager.fileExists(atPath: $0.path)
            }
            if !hasConflict {
                return destinations
            }

            candidate = directory
                .appendingPathComponent("\(initialStem) (\(index))")
                .appendingPathExtension("mp4")
            index += 1
        }
    }

    private func ensureExportDiskSpace(
        for pendingRecording: PendingRecording,
        modes: Set<VoiceExportMode>
    ) throws {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: pendingRecording.videoURL.path
        ), let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return
        }
        let margin = max(512_000_000, size / 5)
        let requiredCapacity = size * Int64(modes.count) + margin
        let outputDirectory = pendingRecording.finalVideoURL.deletingLastPathComponent()
        guard let values = try? outputDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let availableCapacity = values.volumeAvailableCapacityForImportantUsage else {
            return
        }
        if availableCapacity < requiredCapacity {
            throw CaptureError.insufficientExportDiskSpace
        }
    }

    private func availableOutputURL(startingAt desiredURL: URL) -> URL {
        let fileManager = FileManager.default
        let directory = desiredURL.deletingLastPathComponent()
        let stem = desiredURL.deletingPathExtension().lastPathComponent
        var candidate = desiredURL
        var index = 2
        while fileManager.fileExists(atPath: candidate.path)
            || fileManager.fileExists(
                atPath: TimeFormatting.voiceOutputURL(matching: candidate).path
            ) {
            candidate = directory
                .appendingPathComponent("\(stem) (\(index))")
                .appendingPathExtension("mp4")
            index += 1
        }
        return candidate
    }

    private func setAcceptingSamples(_ value: Bool) {
        lifecycleLock.lock()
        acceptingSamples = value
        lifecycleLock.unlock()
    }

    private func shouldAcceptSamples() -> Bool {
        lifecycleLock.lock()
        let result = acceptingSamples
        lifecycleLock.unlock()
        return result
    }

    private func drainSampleQueue() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                continuation.resume()
            }
        }
    }

    private func prepareFirstFrameWait(requiresMicrophone: Bool) {
        firstFrameLock.lock()
        firstFrameContinuation = nil
        hasReceivedFirstFrame = false
        requiresMicrophoneSample = requiresMicrophone
        hasReceivedMicrophoneSample = false
        firstFrameGeneration = UUID()
        firstFrameLock.unlock()
    }

    private func waitForFirstFrame() async throws {
        try await withCheckedThrowingContinuation { continuation in
            firstFrameLock.lock()
            if hasReceivedFirstFrame,
               !requiresMicrophoneSample || hasReceivedMicrophoneSample {
                firstFrameLock.unlock()
                continuation.resume()
                return
            }
            firstFrameContinuation = continuation
            let generation = firstFrameGeneration
            firstFrameLock.unlock()

            Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.failFirstFrameWaitIfNeeded(generation: generation)
            }
        }
    }

    private func signalFirstFrame() {
        firstFrameLock.lock()
        hasReceivedFirstFrame = true
        let isReady = !requiresMicrophoneSample || hasReceivedMicrophoneSample
        let continuation = isReady ? firstFrameContinuation : nil
        if isReady {
            firstFrameContinuation = nil
        }
        firstFrameLock.unlock()
        continuation?.resume()
    }

    private func signalFirstMicrophoneSample() {
        firstFrameLock.lock()
        hasReceivedMicrophoneSample = true
        let continuation = hasReceivedFirstFrame ? firstFrameContinuation : nil
        if hasReceivedFirstFrame {
            firstFrameContinuation = nil
        }
        firstFrameLock.unlock()
        continuation?.resume()
    }

    private func failFirstFrameWaitIfNeeded(generation: UUID) {
        firstFrameLock.lock()
        let requiredSamplesAreReady = hasReceivedFirstFrame
            && (!requiresMicrophoneSample || hasReceivedMicrophoneSample)
        guard generation == firstFrameGeneration, !requiredSamplesAreReady else {
            firstFrameLock.unlock()
            return
        }
        let continuation = firstFrameContinuation
        let error: Error = hasReceivedFirstFrame && requiresMicrophoneSample
            ? CaptureError.noMicrophoneSamples
            : CaptureError.noVideoFrames
        firstFrameContinuation = nil
        firstFrameLock.unlock()
        continuation?.resume(throwing: error)
    }

    private func clearFirstFrameWait() {
        firstFrameLock.lock()
        let continuation = firstFrameContinuation
        firstFrameContinuation = nil
        hasReceivedFirstFrame = false
        requiresMicrophoneSample = false
        hasReceivedMicrophoneSample = false
        firstFrameGeneration = UUID()
        firstFrameLock.unlock()
        continuation?.resume(throwing: CaptureError.streamStopped("录制已停止。"))
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentsArray.first,
        let rawStatus = attachments[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }

    private static func isBrowserWindow(_ window: SCWindow) -> Bool {
        guard window.windowLayer == 0,
              window.frame.width >= 360,
              window.frame.height >= 240,
              let application = window.owningApplication else { return false }

        let identifiers: Set<String> = [
            "com.apple.Safari",
            "com.apple.SafariTechnologyPreview",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.brave.Browser",
            "com.kagi.kagimacOS",
            "com.operasoftware.Opera"
        ]
        if identifiers.contains(application.bundleIdentifier) { return true }

        let name = application.applicationName.lowercased()
        return ["safari", "chrome", "edge", "arc", "firefox", "brave", "orion", "opera"]
            .contains(where: name.contains)
    }
}

extension ScreenCaptureService: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard shouldAcceptSamples() else { return }
        switch outputType {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            if writer?.appendVideo(sampleBuffer) == true {
                signalFirstFrame()
            }
        case .audio:
            writer?.appendAudio(sampleBuffer)
        case .microphone:
            if writer?.appendMicrophone(sampleBuffer) == true {
                signalFirstMicrophoneSample()
            }
        @unknown default:
            break
        }
    }
}

extension ScreenCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.isStopping,
                  stream === self.stream else { return }
            self.unexpectedStopHandler?(error)
        }
    }
}
