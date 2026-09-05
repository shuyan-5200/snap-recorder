import AVFoundation
import CoreMedia
import CoreImage
import CoreVideo
import Foundation

/// Camera timestamps use the host clock, matching ScreenCaptureKit timestamps.
struct CameraFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

/// A short history lets the screen writer choose a nearby, already-captured frame.
final class CameraFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: [CameraFrame] = []
    private let capacity = 3
    private let futureTolerance = CMTime(value: 1, timescale: 120)
    private let maximumAge = 0.5

    func append(_ frame: CameraFrame) {
        guard frame.presentationTime.isNumeric else { return }
        lock.lock()
        defer { lock.unlock() }

        // Normally timestamps arrive in order. Keep that invariant even if a
        // device delivers one late frame, so it cannot displace a newer frame.
        let index = storedFrames.firstIndex {
            CMTimeCompare($0.presentationTime, frame.presentationTime) > 0
        } ?? storedFrames.endIndex
        storedFrames.insert(frame, at: index)
        if storedFrames.count > capacity {
            storedFrames.removeFirst(storedFrames.count - capacity)
        }
    }

    func frame(at screenHostTime: CMTime) -> CameraFrame? {
        guard screenHostTime.isNumeric else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let latestAllowedTime = CMTimeAdd(screenHostTime, futureTolerance)
        guard let candidate = storedFrames.last(where: {
            CMTimeCompare($0.presentationTime, latestAllowedTime) <= 0
        }) else { return nil }
        let age = CMTimeGetSeconds(CMTimeSubtract(screenHostTime, candidate.presentationTime))
        guard age.isFinite, age <= maximumAge else { return nil }
        return candidate
    }

    func latestFrame() -> CameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames.last
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storedFrames.removeAll(keepingCapacity: true)
    }
}

enum CameraCaptureError: LocalizedError {
    case permissionRequired
    case unavailable
    case cannotConfigure
    case cannotAllocateFrame
    case didNotStart
    case interrupted
    case disconnected
    case stoppedDeliveringFrames
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "请先在系统设置中允许 Snap Recorder 使用摄像头。"
        case .unavailable:
            return "没有找到可用的摄像头，请连接摄像头后重试。"
        case .cannotConfigure:
            return "暂时无法连接摄像头，请关闭其他正在使用摄像头的应用后重试。"
        case .cannotAllocateFrame:
            return "无法处理摄像头画面，请关闭一些应用后重试。"
        case .didNotStart:
            return "摄像头未能传来画面，请检查连接或关闭其他正在使用摄像头的应用后重试。"
        case .interrupted:
            return "摄像头被系统中断，请重新开启摄像头后重试。"
        case .disconnected:
            return "摄像头已断开连接，请重新连接后重试。"
        case .stoppedDeliveringFrames:
            return "摄像头画面已中断，请重新开启摄像头后重试。"
        case .runtime(let message):
            return "摄像头暂时不可用：\(message)"
        }
    }
}

/// Owns only video capture. Permission prompts belong to AppModel, and enabling
/// this service never opens a microphone input or requests audio permission.
final class CameraCaptureService: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let frames = CameraFrameStore()

    var failureHandler: ((String) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return storedFailureHandler
        }
        set {
            callbackLock.lock()
            storedFailureHandler = newValue
            callbackLock.unlock()
        }
    }

    // Session configuration, start/stop, notifications and delegate delivery all
    // use this queue. No synchronous camera operation blocks the main thread.
    private let queue = DispatchQueue(
        label: "io.github.shuyan-5200.SnapRecorder.camera",
        qos: .userInitiated
    )
    private var videoOutput: AVCaptureVideoDataOutput?
    private var generation: UUID?
    private var hasReceivedFrame = false
    private var startupTime: UInt64 = 0
    private var lastFrameArrivalTime: UInt64 = 0
    private var startupWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var framePool: CVPixelBufferPool?
    private var framePoolWidth = 0
    private var framePoolHeight = 0
    private var portraitSettings = CameraPortraitSettings()
    private let portraitProcessor = CameraPortraitProcessor()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let imageColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let callbackLock = NSLock()
    private var storedFailureHandler: ((String) -> Void)?
    private var callbackGeneration = UUID()

    private final class StartRequest: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    func start() async throws {
        let request = StartRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    beginStart(request: request, continuation: continuation)
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            // Mark immediately: cancellation may happen before beginStart has
            // reached the queue, in which case hardware must never be started.
            request.cancel()
            self.queue.async { [self] in
                cancelStartup(request.id)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                invalidateFailureCallback()
                finishSession(error: CancellationError(), notifyFailure: false)
                continuation.resume()
            }
        }
    }

    func setPortraitSettings(_ settings: CameraPortraitSettings) {
        queue.async { [self] in
            if portraitSettings != settings {
                portraitSettings = settings
                // Old masks must never survive a disable/re-enable cycle.
                if !settings.isEnabled { portraitProcessor.reset() }
            }
        }
    }

    private func beginStart(
        request: StartRequest,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !request.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if generation != nil {
            if hasReceivedFrame {
                continuation.resume()
            } else {
                startupWaiters[request.id] = continuation
            }
            return
        }

        invalidateFailureCallback()
        let activeGeneration = UUID()
        generation = activeGeneration
        startupWaiters[request.id] = continuation
        hasReceivedFrame = false
        frames.clear()

        do {
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                throw CameraCaptureError.permissionRequired
            }

            // Prefer the physical built-in camera, even when Continuity Camera
            // happens to be macOS's current default camera.
            let builtIn = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera],
                mediaType: .video,
                position: .unspecified
            ).devices.first(where: { $0.isConnected && !$0.isContinuityCamera })
            guard let device = builtIn ?? AVCaptureDevice.default(for: .video), device.isConnected else {
                throw CameraCaptureError.unavailable
            }
            try configureSession(device: device)
            installObservers(device: device, generation: activeGeneration)

            startupTime = DispatchTime.now().uptimeNanoseconds
            lastFrameArrivalTime = 0
            installWatchdog(generation: activeGeneration)
            session.startRunning()
            if !session.isRunning {
                throw CameraCaptureError.didNotStart
            }
            // Success is intentionally deferred until the delegate receives a
            // valid image and converts its actual timestamp to the host clock.
        } catch {
            finishSession(error: error, notifyFailure: false)
        }
    }

    private func configureSession(device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }
        guard session.canAddInput(input) else {
            throw CameraCaptureError.cannotConfigure
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            throw CameraCaptureError.cannotConfigure
        }
        session.addOutput(output)
        videoOutput = output
        output.setSampleBufferDelegate(self, queue: queue)

        // Keep source pixels unmirrored; the same explicit mirror setting is
        // applied by both the preview and the recording compositor.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        }) {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let frameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
        }
    }

    private func cancelStartup(_ id: UUID) {
        guard let continuation = startupWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        if startupWaiters.isEmpty, !hasReceivedFrame {
            invalidateFailureCallback()
            finishSession(error: CancellationError(), notifyFailure: false)
        }
    }

    private func installObservers(device: AVCaptureDevice, generation activeGeneration: UUID) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                ?? "摄像头连接发生错误。"
            self?.enqueueFailure(.runtime(message), generation: activeGeneration)
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueFailure(.interrupted, generation: activeGeneration)
        })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            self?.enqueueFailure(.disconnected, generation: activeGeneration)
        })
    }

    private func enqueueFailure(_ error: CameraCaptureError, generation expectedGeneration: UUID) {
        queue.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.finishSession(error: error, notifyFailure: self.hasReceivedFrame)
        }
    }

    private func installWatchdog(generation activeGeneration: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == activeGeneration else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if !self.hasReceivedFrame {
                if now - self.startupTime >= 3_000_000_000 {
                    self.finishSession(error: CameraCaptureError.didNotStart, notifyFailure: false)
                }
            } else if now - self.lastFrameArrivalTime >= 2_000_000_000 {
                self.finishSession(error: CameraCaptureError.stoppedDeliveringFrames, notifyFailure: true)
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func finishSession(error: Error, notifyFailure: Bool) {
        let shouldNotify = generation != nil && notifyFailure
        generation = nil
        watchdog?.cancel()
        watchdog = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        // Detach first, then stop hardware. Any already-enqueued delegate call
        // is rejected because generation/videoOutput no longer match.
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoOutput = nil
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        frames.clear()
        framePool = nil
        portraitProcessor.reset()
        framePoolWidth = 0
        framePoolHeight = 0
        hasReceivedFrame = false
        startupTime = 0
        lastFrameArrivalTime = 0

        let waiters = Array(startupWaiters.values)
        startupWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }

        if shouldNotify {
            reportFailure(error.localizedDescription)
        }
    }

    private func invalidateFailureCallback() {
        callbackLock.lock()
        callbackGeneration = UUID()
        callbackLock.unlock()
    }

    private func reportFailure(_ message: String) {
        callbackLock.lock()
        let expectedGeneration = callbackGeneration
        callbackLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            let callback = self.callbackGeneration == expectedGeneration ? self.storedFailureHandler : nil
            self.callbackLock.unlock()
            callback?(message)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard generation != nil,
              output === videoOutput,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let sessionClock = session.synchronizationClock else { return }
        let cameraTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard cameraTime.isNumeric else { return }
        let hostTime = CMSyncConvertTime(cameraTime, from: sessionClock, to: CMClockGetHostTimeClock())
        guard hostTime.isNumeric else { return }

        do {
            guard let ownedBuffer = try copyFrame(pixelBuffer, presentationTime: hostTime) else { return }
            frames.append(CameraFrame(pixelBuffer: ownedBuffer, presentationTime: hostTime))
        } catch {
            // Let AVFoundation's delegate call return before stopping hardware.
            if let generation {
                enqueueFailure(
                    error as? CameraCaptureError ?? .runtime(error.localizedDescription),
                    generation: generation
                )
            }
            return
        }
        // Arrival time is used only for liveness, never as the frame's PTS.
        lastFrameArrivalTime = DispatchTime.now().uptimeNanoseconds
        if !hasReceivedFrame {
            hasReceivedFrame = true
            let waiters = Array(startupWaiters.values)
            startupWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// Return the device-owned buffer immediately after this delegate callback.
    /// Holding camera buffers for history/composition can exhaust AVFoundation's
    /// pool and stop both capture output and the live preview (Apple TN2445).
    private func copyFrame(_ source: CVPixelBuffer, presentationTime: CMTime) throws -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            throw CameraCaptureError.cannotAllocateFrame
        }

        if framePool == nil || framePoolWidth != width || framePoolHeight != height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                poolAttributes as CFDictionary,
                attributes as CFDictionary,
                &pool
            ) == kCVReturnSuccess, let pool else {
                throw CameraCaptureError.cannotAllocateFrame
            }
            framePool = pool
            framePoolWidth = width
            framePoolHeight = height
        }
        guard let framePool else { throw CameraCaptureError.cannotAllocateFrame }

        // Three history frames plus the writer's in-flight frame and a new copy
        // fit without allowing a slow encoder to grow camera memory unbounded.
        let auxiliaryAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: 6]
        var copy: CVPixelBuffer?
        let allocationResult = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            framePool,
            auxiliaryAttributes as CFDictionary,
            &copy
        )
        if allocationResult == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard allocationResult == kCVReturnSuccess, let copy else {
            throw CameraCaptureError.cannotAllocateFrame
        }

        // Process once, before publication: preview and encoder consume the
        // exact same camera pixels. The screen itself never enters this filter.
        if portraitSettings.isEnabled {
            let image = portraitProcessor.process(
                source, settings: portraitSettings, presentationTime: presentationTime
            )
            imageContext.render(
                image, to: copy,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                colorSpace: imageColorSpace
            )
            // CI rendered into sRGB; do not retain device color tags that can
            // make the same processed frame look different downstream.
            CVBufferSetAttachment(copy, kCVImageBufferCGColorSpaceKey, imageColorSpace, .shouldPropagate)
            return copy
        }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw CameraCaptureError.cannotAllocateFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else {
            throw CameraCaptureError.cannotAllocateFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(copy, []) }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(copy) else {
            throw CameraCaptureError.cannotAllocateFrame
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = width * 4
        guard sourceStride >= rowBytes, destinationStride >= rowBytes else {
            throw CameraCaptureError.cannotAllocateFrame
        }
        for row in 0..<height {
            memcpy(
                destinationBase.advanced(by: row * destinationStride),
                sourceBase.advanced(by: row * sourceStride),
                rowBytes
            )
        }
        CVBufferPropagateAttachments(source, copy)
        return copy
    }
}
