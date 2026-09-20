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
    // Camera recordings need an independent cadence: an idle SCStream frame
    // contains no new pixels, while the camera must continue to move.
    private var cameraFrames: CameraFrameStore?
    private var cameraVideoTimer: DispatchSourceTimer?
    private var latestScreenBuffer: CVPixelBuffer?
    private var finalOutputURL: URL?
    private var temporaryOutputURL: URL?
    private var temporaryMicrophoneURL: URL?
    private var pendingRecording: PendingRecording?
    private var isExporting = false
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

    var hasRetryableAutomaticSave: Bool {
        guard let pendingRecording else { return false }
        return pendingRecording.microphoneURL == nil
    }

    func installPendingRecordingForSelfTest(
        videoURL: URL,
        microphoneURL: URL?,
        finalVideoURL: URL
    ) throws {
        guard (CommandLine.arguments.contains("--self-test") || RecordingDiagnostics.isExportPreview), pendingRecording == nil else {
            throw CaptureError.couldNotStartWriter("自检导出状态无法初始化。")
        }
        pendingRecording = PendingRecording(
            videoURL: videoURL,
            microphoneURL: microphoneURL,
            finalVideoURL: finalVideoURL
        )
        recoveryURLs = [videoURL, microphoneURL].compactMap { $0 }
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

    func capturableMainWindow(windowID: CGWindowID?) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let windowID, let window = content.windows.first(where: {
            $0.windowID == windowID && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }) else {
            throw CaptureError.couldNotStartWriter("无法准备主面板，请重新打开 Snap Recorder 后再试。")
        }
        return window
    }

    static func displayFilter(display: SCDisplay, content: SCShareableContent, mainPanel: SCWindow?) throws -> SCContentFilter {
        let processID = ProcessInfo.processInfo.processIdentifier
        guard let ownApplication = content.applications.first(where: { $0.processID == processID })
                ?? mainPanel?.owningApplication, ownApplication.processID == processID else {
            // Never fall back to capturing auxiliary windows if enumeration fails.
            throw CaptureError.couldNotStartWriter("无法隐藏录制控制条，请重试。")
        }
        let exceptions = mainPanel.map { $0.owningApplication?.processID == processID ? [$0] : [] } ?? []
        return SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: exceptions)
    }

    func start(_ request: CaptureRequest, cameraFrames: CameraFrameStore? = nil, mainPanel: SCWindow? = nil) async throws {
        guard pendingRecording == nil else {
            throw CaptureError.couldNotStartWriter("请先完成或放弃上一段录制。")
        }
        recoveryURLs = []
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionRequired
        }
        if request.cameraOverlay != nil {
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                  cameraFrames?.frame(at: CMClockGetTime(CMClockGetHostTimeClock())) != nil else {
                throw CaptureError.couldNotStartWriter("摄像头尚未准备好，请重新开启摄像头后重试。")
            }
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
        let sourceRect: CGRect?
        let mouseCaptureRect: CGRect

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
            sourceRect = nil
            mouseCaptureRect = window.frame

        case .display:
            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                ?? content.displays.first else {
                throw CaptureError.noDisplay
            }

            filter = try Self.displayFilter(display: display, content: content, mainPanel: mainPanel)

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
            sourceRect = nil
            mouseCaptureRect = display.frame

        case .region:
            guard let region = request.region else {
                throw CaptureError.noCaptureRegion
            }
            guard let display = content.displays.first(where: {
                $0.displayID == region.displayID
            }) else {
                throw CaptureError.captureRegionUnavailable
            }

            filter = try Self.displayFilter(display: display, content: content, mainPanel: mainPanel)

            let displayBounds = CGRect(origin: .zero, size: display.frame.size)
            let selectedRect = region.sourceRect.intersection(displayBounds).integral
            guard selectedRect.width >= 2, selectedRect.height >= 2 else {
                throw CaptureError.captureRegionUnavailable
            }
            sourceRect = selectedRect
            let sourcePixels = CGSize(
                width: selectedRect.width * CGFloat(filter.pointPixelScale),
                height: selectedRect.height * CGFloat(filter.pointPixelScale)
            )
            outputSize = CaptureSizing.regionOutputSize(source: sourcePixels)
            streamSize = outputSize
            mouseCaptureRect = CGRect(
                x: display.frame.minX + selectedRect.minX,
                y: display.frame.minY + selectedRect.minY,
                width: selectedRect.width,
                height: selectedRect.height
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(streamSize.width)
        configuration.height = Int(streamSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(ExportPlanning.frameRate))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        // The system arrow is always hidden. When enabled, RecordingWriter
        // draws Snap Recorder's own circular pointer and click ripple.
        configuration.showsCursor = false
        configuration.capturesAudio = request.capturesSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.colorSpaceName = CGColorSpace.sRGB as CFString
        configuration.shouldBeOpaque = true
        configuration.captureResolution = .best
        if let sourceRect {
            configuration.sourceRect = sourceRect
            configuration.destinationRect = CGRect(origin: .zero, size: streamSize)
        }

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
                qualityPreset: .maximum,
                capturesAudio: request.capturesSystemAudio,
                microphoneOutputURL: microphoneURL,
                captureCornerStyle: request.captureCornerStyle,
                appliesSoftCornerVignette: request.appliesSoftCornerVignette,
                focusMask: request.focusMask,
                mouseCaptureRect: request.capturesMouseEffects ? mouseCaptureRect : nil,
                cameraOverlay: request.cameraOverlay
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
            self.cameraFrames = request.cameraOverlay == nil ? nil : cameraFrames
            finalOutputURL = request.outputURL
            temporaryOutputURL = temporaryURL
            temporaryMicrophoneURL = microphoneURL
            isStopping = false
            setAcceptingSamples(true)
            prepareFirstFrameWait(requiresMicrophone: request.capturesMicrophone)

            try await stream.startCapture()
            if request.cameraOverlay != nil {
                await startCameraVideoClock()
            }
            try await waitForFirstFrame()
        } catch {
            isStopping = true
            setAcceptingSamples(false)
            if let createdStream {
                try? await createdStream.stopCapture()
            }
            await drainSampleQueue()
            await stopCameraVideoClock()
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
        await stopCameraVideoClock()

        guard let writer,
              let temporaryOutputURL,
              let finalOutputURL else {
            reset()
            throw CaptureError.couldNotFinishWriter("录制器尚未启动。")
        }

        do {
            try await writer.finish()
            let pending = PendingRecording(
                videoURL: temporaryOutputURL,
                microphoneURL: temporaryMicrophoneURL,
                finalVideoURL: finalOutputURL
            )
            reset(keepTemporaryFile: true)
            pendingRecording = pending
            recoveryURLs = [temporaryOutputURL, temporaryMicrophoneURL]
                .compactMap { $0 }
            return .awaitingExportChoice
        } catch {
            let recoverableURLs = [temporaryOutputURL, temporaryMicrophoneURL]
                .compactMap { $0 }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            reset(keepTemporaryFile: true)
            recoveryURLs = recoverableURLs
            throw error
        }
    }

    var hasPendingRecording: Bool { pendingRecording != nil }

    func pendingExportInfo() async throws -> RecordingExportInfo {
        guard let pendingRecording else {
            throw CaptureError.couldNotFinishWriter("没有等待导出的录制内容。")
        }
        let asset = AVURLAsset(url: pendingRecording.videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.couldNotFinishWriter("无法读取录制画面。")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayedSize = size.applying(transform)
        return RecordingExportInfo(
            duration: try await asset.load(.duration).seconds,
            size: CGSize(width: abs(displayedSize.width), height: abs(displayedSize.height)),
            sourceBytes: try ExportPlanning.fileBytes(pendingRecording.videoURL),
            hasSystemAudio: try await !asset.loadTracks(withMediaType: .audio).isEmpty,
            sourceVideoBitrate: Double(try await track.load(.estimatedDataRate)),
            sourceFrameRate: Double(try await track.load(.nominalFrameRate)),
            hasMicrophone: pendingRecording.microphoneURL != nil
        )
    }

    /// Only owned source files are removed; saved exports never belong to this list.
    func discardPendingRecording(moveToTrash: Bool = false) throws {
        guard !isExporting, stream == nil else { return }
        let sources = pendingRecording.map { [$0.videoURL, $0.microphoneURL].compactMap { $0 } } ?? recoveryURLs
        for url in sources where FileManager.default.fileExists(atPath: url.path) {
            if moveToTrash {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        pendingRecording = nil
        recoveryURLs = []
    }

    func retryPendingAutomaticSave() throws -> RecordingResult {
        guard let pendingRecording else {
            throw CaptureError.couldNotFinishWriter("没有可重试保存的录制内容。")
        }
        let outputURL = availableOutputURL(startingAt: pendingRecording.finalVideoURL)
        try copyCompletedRecording(from: pendingRecording.videoURL, to: outputURL)
        return RecordingResult(urls: [outputURL])
    }

    func exportPendingRecording(
        qualityPreset: RecordingQualityPreset,
        selection: RecordingExportSelection,
        name: String? = nil,
        customMegabytes: Double? = nil
    ) async throws -> RecordingResult {
        guard let pendingRecording, !isExporting else {
            throw CaptureError.couldNotFinishWriter("没有等待导出的录制内容，或导出正在进行。")
        }
        let fallback = pendingRecording.finalVideoURL.deletingPathExtension().lastPathComponent
        let stem = try ExportPlanning.validatedName(name ?? fallback, fallback: fallback)
        let desiredURL = pendingRecording.finalVideoURL.deletingLastPathComponent()
            .appendingPathComponent(stem).appendingPathExtension("mp4")
        isExporting = true
        var temporaryURLs: [URL] = []
        var committedURLs: [URL] = []
        defer {
            isExporting = false
            for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        }
        func temporary(_ extensionName: String) throws -> URL {
            let url = try makeTemporaryOutputURL(pathExtension: extensionName)
            temporaryURLs.append(url)
            return url
        }

        do {
            try Task.checkCancellation()
            let info = try await pendingExportInfo()
            try selection.validate(available: info.availableTracks)
            try ensureExportDiskSpace(for: pendingRecording, selection: selection, duration: info.duration)
            var stagedVideo: URL?
            if selection.includesVideo {
                var videoSource = pendingRecording.videoURL
                if info.hasSystemAudio && !selection.includesSystemInVideo {
                    let muted = try temporary("mp4")
                    try await RecordingExporter.copyVideoOnly(sourceURL: videoSource, outputURL: muted)
                    videoSource = muted
                }
                let sourceBytes = try ExportPlanning.fileBytes(videoSource)
                func plan(scale: Double = 1, resolutionScale: Double = 1) throws -> VideoExportPlan {
                    try ExportPlanning.plan(
                        sourceSize: info.size, duration: info.duration, preset: qualityPreset,
                        customMegabytes: customMegabytes, hasSystemAudio: selection.includesSystemInVideo,
                        sourceVideoBitrate: info.sourceVideoBitrate, sourceFrameRate: info.sourceFrameRate,
                        sourceBytes: sourceBytes,
                        includesCombinedVoice: selection.includesVoiceInVideo,
                        bitrateScale: scale, resolutionScale: resolutionScale
                    )
                }
                let initialPlan = try plan()
                let byteCeiling: Int64? = qualityPreset == .maximum ? nil
                    : initialPlan.byteLimit ?? ExportPlanning.estimatedByteCeiling(for: initialPlan, duration: info.duration)
                var scale = 1.0, resolutionScale = 1.0
                for attempt in 0..<4 {
                    let currentPlan = try plan(scale: scale, resolutionScale: resolutionScale)
                    let video = try temporary("mp4")
                    if currentPlan.preservesSource {
                        try FileManager.default.copyItem(at: videoSource, to: video)
                    } else {
                        try await RecordingExporter.compressVideo(sourceURL: videoSource, outputURL: video, plan: currentPlan)
                    }
                    if qualityPreset == .maximum {
                        let smaller = try ExportPlanning.fileBytes(video) < sourceBytes
                        var preservesDetail = false
                        if smaller {
                            do {
                                preservesDetail = try await RecordingExporter.preservesHighQuality(
                                    sourceURL: videoSource, candidateURL: video, duration: info.duration
                                )
                            } catch is CancellationError { throw CancellationError() }
                            catch { /* Keep the master if comparison is unavailable. */ }
                        }
                        if info.sourceFrameRate > 0,
                           info.sourceFrameRate <= Double(ExportPlanning.frameRate) + 0.001,
                           (!smaller || !preservesDetail) {
                            try FileManager.default.removeItem(at: video)
                            try FileManager.default.copyItem(at: videoSource, to: video)
                        }
                    }
                    var result = video
                    if selection.includesVoiceInVideo, let microphone = pendingRecording.microphoneURL {
                        let mixed = try temporary("mp4")
                        try await RecordingExporter.combine(
                            videoURL: video, microphoneURL: microphone, outputURL: mixed,
                            audioBitrate: qualityPreset.audioBitrate,
                            includesSystemAudio: selection.includesSystemInVideo
                        )
                        result = mixed
                    }
                    stagedVideo = result
                    guard let limit = byteCeiling else { break }
                    let bytes = try ExportPlanning.fileBytes(result)
                    if CommandLine.arguments.contains("--self-test") {
                        fputs("Size ceiling attempt \(attempt + 1): \(Int(currentPlan.size.width))x\(Int(currentPlan.size.height)), \(bytes)/\(limit) bytes\n", stderr)
                    }
                    if bytes <= limit { break }
                    guard attempt < 3 else {
                        throw CaptureError.couldNotFinishWriter("无法满足这个大小，请提高上限。")
                    }
                    let ratio = Double(limit) / Double(bytes)
                    scale *= ratio * 0.85
                    resolutionScale *= min(0.9, sqrt(ratio) * 0.95)
                    try FileManager.default.removeItem(at: video)
                    if result != video { try FileManager.default.removeItem(at: result) }
                    stagedVideo = nil
                }
            }

            let destinations = availableExportDestinations(startingAt: desiredURL, kinds: selection.files)
            var staged: [URL] = []
            let timingVideo = stagedVideo ?? pendingRecording.videoURL
            for kind in selection.files {
                try Task.checkCancellation()
                switch kind {
                case .mergedVideo, .video:
                    guard let stagedVideo else { throw CaptureError.couldNotFinishWriter("没有完成的视频。") }
                    staged.append(stagedVideo)
                case .systemAudio:
                    let audio = try temporary("m4a")
                    try await RecordingExporter.alignAudio(
                        sourceURL: pendingRecording.videoURL, matchingVideoURL: timingVideo,
                        outputURL: audio, channels: 2
                    )
                    staged.append(audio)
                case .voice:
                    guard let microphone = pendingRecording.microphoneURL else { throw CaptureError.noMicrophoneSamples }
                    let audio = try temporary("m4a")
                    try await RecordingExporter.alignVoice(microphoneURL: microphone, matchingVideoURL: timingVideo, outputURL: audio)
                    staged.append(audio)
                case .mixedAudio:
                    guard let microphone = pendingRecording.microphoneURL else { throw CaptureError.noMicrophoneSamples }
                    let audio = try temporary("m4a")
                    try await RecordingExporter.combine(videoURL: pendingRecording.videoURL,
                        microphoneURL: microphone, outputURL: audio, audioBitrate: 192_000,
                        includesSystemAudio: true, includesVideo: false)
                    staged.append(audio)
                }
            }
            try Task.checkCancellation()
            for (source, destination) in zip(staged, destinations) {
                try moveCompletedRecording(from: source, to: destination)
                committedURLs.append(destination)
            }
            return RecordingResult(urls: committedURLs)
        } catch {
            for url in committedURLs { try? FileManager.default.removeItem(at: url) }
            recoveryURLs = [pendingRecording.videoURL, pendingRecording.microphoneURL].compactMap { $0 }
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

    private func startCameraVideoClock() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                let timer = DispatchSource.makeTimerSource(queue: self.sampleQueue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in
                    guard let self, self.shouldAcceptSamples(),
                          let source = self.latestScreenBuffer else { return }
                    let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
                    guard let frame = self.cameraFrames?.frame(at: hostTime) else { return }
                    if self.writer?.appendVideoFrame(source, at: hostTime, cameraFrame: frame) == true {
                        self.signalFirstFrame()
                    }
                }
                self.cameraVideoTimer = timer
                timer.resume()
                continuation.resume()
            }
        }
    }

    private func stopCameraVideoClock() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                self?.cameraVideoTimer?.cancel()
                self?.cameraVideoTimer = nil
                self?.latestScreenBuffer = nil
                self?.cameraFrames = nil
                continuation.resume()
            }
        }
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

    private func availableExportDestinations(startingAt desiredURL: URL, kinds: [ExportFileKind]) -> [URL] {
        let directory = desiredURL.deletingLastPathComponent()
        let stem = desiredURL.deletingPathExtension().lastPathComponent
        var candidate = desiredURL
        var index = 2
        while true {
            let urls = kinds.map { kind in
                switch kind {
                case .mergedVideo: candidate
                case .video: TimeFormatting.separateVideoOutputURL(matching: candidate)
                case .voice: TimeFormatting.voiceOutputURL(matching: candidate)
                case .systemAudio: TimeFormatting.audioOutputURL(matching: candidate, title: "电脑声音")
                case .mixedAudio: TimeFormatting.audioOutputURL(matching: candidate, title: "声音")
                }
            }
            if !urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { return urls }
            candidate = directory.appendingPathComponent("\(stem) (\(index))").appendingPathExtension("mp4")
            index += 1
        }
    }

    private func ensureExportDiskSpace(
        for pendingRecording: PendingRecording, selection: RecordingExportSelection, duration: Double
    ) throws {
        let size = try ExportPlanning.fileBytes(pendingRecording.videoURL)
        let estimated = selection.includesVideo ? size * 3 : Int64(duration * 24_000 * Double(selection.files.count))
        let required = estimated + max(32_000_000, estimated / 5)
        let directory = pendingRecording.finalVideoURL.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        if available < required { throw CaptureError.insufficientExportDiskSpace }
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
            if cameraFrames != nil {
                latestScreenBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
                return
            }
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
