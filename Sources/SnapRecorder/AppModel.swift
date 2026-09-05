import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: CaptureMode = .browser
    @Published var capturesSystemAudio = true
    @Published var capturesMicrophone = false
    @Published var capturesMouseEffects = true
    @Published private(set) var capturesCamera = false
    @Published private(set) var isPreparingCamera = false
    @Published private(set) var cameraReady = false
    @Published var cameraMessage: String?
    @Published var cameraSettings = CameraOverlaySettings()
    let cameraService = CameraCaptureService()
    private var cameraGeneration = UUID()
    private var cameraOperation: Task<Void, Never>?
    private var cameraFailureDuringCountdown: String?
    @Published var isRequestingMicrophonePermission = false
    @Published var microphoneMessage: String?
    @Published var browserWindows: [BrowserWindowInfo] = []
    @Published var selectedBrowserWindowID: CGWindowID?
    @Published var phase: RecordingPhase = .idle
    @Published var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published var hasRequestedPermission = false
    @Published var isLoadingWindows = false
    @Published var browserSelectionNote: String?
    @Published var browserListError: String?
    @Published var selectedRegionAspectRatio: CaptureAspectRatio = .widescreen
    @Published var captureRegion: CaptureRegion?
    @Published var captureRegionCornerStyle: FocusMaskCornerStyle = .rounded
    @Published var appliesSoftCornerVignette = false
    @Published var isFocusMaskEnabled = false
    @Published var focusMaskCornerStyle: FocusMaskCornerStyle = .rounded
    @Published var focusMask: CaptureFocusMask?
    @Published var isRegionSelectionLocked = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var lastRecordingResult: RecordingResult?
    @Published var errorMessage: String?
    @Published var completionNote: String?
    @Published var hasRetryableSave = false
    @Published var recoveryURLs: [URL] = []
    @Published var selectedQualityPreset: RecordingQualityPreset = .maximum
    @Published var selectedVoiceExportModes: Set<VoiceExportMode> = [.combined]

    private let captureService: ScreenCaptureService
    private unowned let windowCoordinator: WindowCoordinator
    private var elapsedTimer: Timer?
    private var activeRecordingBeganAt: Date?
    private var elapsedBeforeCurrentSegment: TimeInterval = 0
    private var isHandlingUnexpectedStop = false
    private var hasLoadedBrowserWindows = false
    private(set) var activeCapturesSystemAudio = true
    private(set) var activeCapturesMicrophone = false

    init(captureService: ScreenCaptureService, windowCoordinator: WindowCoordinator) {
        self.captureService = captureService
        self.windowCoordinator = windowCoordinator

        captureService.unexpectedStopHandler = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleUnexpectedStop(error)
            }
        }
        cameraService.failureHandler = { [weak self] message in
            // CameraCaptureService delivers failures on the main queue. Preserve
            // this session identity across the asynchronous state transition.
            let generation = MainActor.assumeIsolated { self?.cameraGeneration }
            Task { @MainActor [weak self] in
                guard let self, self.capturesCamera,
                      self.cameraGeneration == generation else { return }
                self.cameraMessage = message
                self.cameraReady = false
                if self.phase == .countdown {
                    self.cameraFailureDuringCountdown = message
                } else if self.phase.isCapturing {
                    await self.handleUnexpectedStop(CaptureError.streamStopped(message))
                } else {
                    self.setCameraCaptureEnabled(false)
                    self.cameraMessage = message
                }
            }
        }
    }

    var selectedBrowserWindow: BrowserWindowInfo? {
        guard let selectedBrowserWindowID else { return nil }
        return browserWindows.first { $0.id == selectedBrowserWindowID }
    }

    var canStartRecording: Bool {
        guard permissionGranted,
              !isRequestingMicrophonePermission,
              !isPreparingCamera,
              phase == .idle || phase == .failed else { return false }
        if capturesCamera, !cameraReady { return false }
        if capturesMicrophone {
            guard microphoneFeatureAvailable,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                return false
            }
        }
        if mode == .browser {
            return selectedBrowserWindow != nil
        }
        if mode == .region {
            return captureRegion != nil
        }
        return true
    }

    var elapsedText: String {
        TimeFormatting.recordingDuration(elapsedTime)
    }

    var microphoneFeatureAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    var lastOutputURLs: [URL] {
        lastRecordingResult?.urls ?? []
    }

    var hasUnfinishedSave: Bool {
        phase == .choosingExport || hasRetryableSave
    }

    var exportButtonTitle: String {
        if !activeCapturesMicrophone {
            return selectedQualityPreset == .maximum
                ? "导出最高画质"
                : "导出清晰小体积"
        }
        switch selectedVoiceExportModes {
        case []:
            return "请至少选择一种"
        case [.combined]:
            return "导出完整视频"
        case [.separate]:
            return "导出 2 个分轨文件"
        default:
            return "导出全部 3 个文件"
        }
    }

    func requestPermission() {
        guard !hasRequestedPermission else {
            recheckPermission()
            return
        }
        hasRequestedPermission = true
        let result = CGRequestScreenCaptureAccess()
        permissionGranted = result || CGPreflightScreenCaptureAccess()

        if permissionGranted {
            Task { await refreshBrowserWindows() }
            captureModeDidChange(mode)
        }
    }

    func recheckPermission() {
        let nowGranted = CGPreflightScreenCaptureAccess()
        permissionGranted = nowGranted
        if !nowGranted {
            isRegionSelectionLocked = false
            windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
            windowCoordinator.updateGlobalShortcuts(
                isRegionPreparing: false,
                isRegionLocked: false,
                isRecording: false
            )
        }
        if nowGranted,
           phase == .idle || phase == .failed || phase == .finished {
            Task { await refreshBrowserWindows() }
        }
        if nowGranted, mode == .region, phase == .idle {
            captureModeDidChange(.region)
        }

        if microphoneFeatureAvailable {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if capturesMicrophone, status != .authorized {
                capturesMicrophone = false
                microphoneMessage = "麦克风权限未开启"
            } else if status == .authorized {
                microphoneMessage = nil
            }
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func setMicrophoneCaptureEnabled(_ enabled: Bool) {
        guard enabled else {
            capturesMicrophone = false
            microphoneMessage = nil
            return
        }
        guard microphoneFeatureAvailable else {
            capturesMicrophone = false
            microphoneMessage = "人声录制需要 macOS 15 或更高版本"
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            capturesMicrophone = true
            microphoneMessage = nil
        case .notDetermined:
            isRequestingMicrophonePermission = true
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                isRequestingMicrophonePermission = false
                capturesMicrophone = granted
                microphoneMessage = granted ? nil : "麦克风权限未开启"
            }
        case .denied, .restricted:
            capturesMicrophone = false
            microphoneMessage = "麦克风权限未开启"
        @unknown default:
            capturesMicrophone = false
            microphoneMessage = "无法确认麦克风权限"
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func setCameraCaptureEnabled(_ enabled: Bool) {
        guard !phase.isCapturing, phase != .countdown else { return }
        let generation = UUID()
        cameraGeneration = generation
        capturesCamera = enabled
        cameraReady = false
        isPreparingCamera = enabled
        cameraMessage = nil
        let previous = cameraOperation
        if !enabled { windowCoordinator.hideCameraPreview() }
        cameraOperation = Task { [weak self] in
            guard let self else { return }
            if !enabled {
                await self.cameraService.stop()
                await previous?.value
                return
            }
            await previous?.value
            guard self.cameraGeneration == generation else { return }
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard self.cameraGeneration == generation else { return }
            guard granted else {
                self.isPreparingCamera = false
                self.capturesCamera = false
                self.cameraMessage = "摄像头权限未开启"
                return
            }
            do {
                try await self.cameraService.start()
                guard self.cameraGeneration == generation else { return }
                self.cameraReady = true
                self.isPreparingCamera = false
                self.updateCameraPreview()
            } catch {
                guard self.cameraGeneration == generation else { return }
                self.isPreparingCamera = false
                self.capturesCamera = false
                self.cameraMessage = error.localizedDescription
                self.windowCoordinator.hideCameraPreview()
            }
        }
    }

    func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    func updateCameraPreview() {
        cameraService.setPortraitSettings(cameraSettings.portrait)
        guard capturesCamera, cameraReady else { return }
        windowCoordinator.showCameraPreview(frames: cameraService.frames, settings: cameraSettings)
    }

    func mainWindowClosed() {
        if phase == .idle || phase == .failed || phase == .finished {
            setCameraCaptureEnabled(false)
            windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
        }
    }

    private func releaseCamera() async {
        cameraGeneration = UUID()
        capturesCamera = false
        cameraReady = false
        isPreparingCamera = false
        windowCoordinator.hideCameraPreview()
        await cameraService.stop()
    }

    func captureModeDidChange(_ newMode: CaptureMode) {
        guard permissionGranted else {
            isRegionSelectionLocked = false
            windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
            windowCoordinator.updateGlobalShortcuts(
                isRegionPreparing: false,
                isRegionLocked: false,
                isRecording: false
            )
            return
        }
        guard newMode == .region else {
            isRegionSelectionLocked = false
            windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
            windowCoordinator.updateGlobalShortcuts(
                isRegionPreparing: false,
                isRegionLocked: false,
                isRecording: false
            )
            return
        }

        captureRegion = windowCoordinator.showRegionSelection(
            aspectRatio: selectedRegionAspectRatio,
            captureCornerStyle: captureRegionCornerStyle,
            focusMaskEnabled: isFocusMaskEnabled,
            focusMaskCornerStyle: focusMaskCornerStyle,
            interactionLocked: isRegionSelectionLocked,
            selectionChanged: { [weak self] region in
                self?.captureRegion = region
            },
            focusMaskChanged: { [weak self] mask in
                self?.focusMask = mask
            }
        )
        windowCoordinator.updateGlobalShortcuts(
            isRegionPreparing: phase == .idle,
            isRegionLocked: isRegionSelectionLocked,
            isRecording: false
        )
    }

    func selectRegionAspectRatio(_ aspectRatio: CaptureAspectRatio) {
        selectedRegionAspectRatio = aspectRatio
        if aspectRatio == .custom, isFocusMaskEnabled {
            isFocusMaskEnabled = false
            focusMask = nil
            windowCoordinator.setRegionFocusMaskEnabled(false)
        }
        captureRegion = windowCoordinator.updateRegionAspectRatio(aspectRatio)
    }

    func setFocusMaskEnabled(_ enabled: Bool) {
        let resolved = enabled && selectedRegionAspectRatio.fixedValue != nil
        isFocusMaskEnabled = resolved
        focusMask = windowCoordinator.setRegionFocusMaskEnabled(resolved)
    }

    func setCaptureRegionCornerStyle(_ style: FocusMaskCornerStyle) {
        captureRegionCornerStyle = style
        windowCoordinator.setRegionCaptureCornerStyle(style)
        if style == .square {
            appliesSoftCornerVignette = false
        }
    }

    func setFocusMaskCornerStyle(_ style: FocusMaskCornerStyle) {
        focusMaskCornerStyle = style
        focusMask = windowCoordinator.setRegionFocusMaskCornerStyle(style)
    }

    func toggleRegionSelectionLock() {
        guard mode == .region, phase == .idle else { return }
        isRegionSelectionLocked = windowCoordinator.toggleRegionSelectionLocked()
        windowCoordinator.updateGlobalShortcuts(
            isRegionPreparing: true,
            isRegionLocked: isRegionSelectionLocked,
            isRecording: false
        )
    }

    func startRecordingFromShortcut() {
        guard canStartRecording else { return }
        startRecording()
    }

    func refreshBrowserWindows() async {
        guard permissionGranted, !isLoadingWindows else { return }
        isLoadingWindows = true
        browserListError = nil
        defer { isLoadingWindows = false }

        do {
            let windows = try await captureService.browserWindows()
            let previousSelection = selectedBrowserWindowID
            browserWindows = windows

            if let previousSelection,
               windows.contains(where: { $0.id == previousSelection }) {
                browserSelectionNote = nil
                hasLoadedBrowserWindows = true
                return
            }

            if hasLoadedBrowserWindows, previousSelection != nil {
                selectedBrowserWindowID = nil
                browserSelectionNote = windows.isEmpty
                    ? nil
                    : "之前选择的窗口已关闭，请重新选择。"
            } else {
                selectedBrowserWindowID = windows.first(where: { $0.isOnScreen })?.id
                    ?? windows.first?.id
                browserSelectionNote = nil
            }
            hasLoadedBrowserWindows = true
        } catch {
            if isScreenCapturePermissionFailure(error) {
                enterScreenCapturePermissionState()
            } else {
                browserListError = error.localizedDescription
            }
        }
    }

    func startRecording() {
        Task { await performStartRecording() }
    }

    func togglePause() {
        Task {
            switch phase {
            case .recording:
                await pauseRecording()
            case .paused:
                await resumeRecording()
            default:
                break
            }
        }
    }

    func stopRecording() {
        Task { await performStopRecording() }
    }

    func toggleVoiceExportMode(_ mode: VoiceExportMode) {
        guard phase == .choosingExport else { return }
        if selectedVoiceExportModes.contains(mode) {
            selectedVoiceExportModes.remove(mode)
        } else {
            selectedVoiceExportModes.insert(mode)
        }
        errorMessage = nil
    }

    func exportRecording() {
        guard phase == .choosingExport,
              !activeCapturesMicrophone || !selectedVoiceExportModes.isEmpty else { return }
        let qualityPreset = selectedQualityPreset
        let modes = selectedVoiceExportModes
        errorMessage = nil
        phase = .exporting
        Task { await performExport(qualityPreset: qualityPreset, modes: modes) }
    }

    func retrySavingRecording() {
        Task { await performRetrySaving() }
    }

    func recordAgain() {
        guard !hasRetryableSave else { return }
        completionNote = nil
        errorMessage = nil
        lastRecordingResult = nil
        recoveryURLs = []
        selectedQualityPreset = .maximum
        selectedVoiceExportModes = [.combined]
        isRegionSelectionLocked = false
        phase = .idle
        if mode == .browser {
            Task { await refreshBrowserWindows() }
        } else if mode == .region {
            captureModeDidChange(.region)
        }
    }

    func revealLastRecording() {
        guard !lastOutputURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastOutputURLs)
    }

    func revealRecoveryFiles() {
        guard !recoveryURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(recoveryURLs)
    }

    private func performStartRecording() async {
        guard canStartRecording else { return }

        if mode == .region {
            isRegionSelectionLocked = windowCoordinator.setRegionSelectionLocked(true)
        }
        windowCoordinator.updateGlobalShortcuts(
            isRegionPreparing: false,
            isRegionLocked: false,
            isRecording: false
        )

        do {
            try ensureDiskSpace()
            errorMessage = nil
            completionNote = nil
            lastRecordingResult = nil
            hasRetryableSave = false
            recoveryURLs = []
            selectedQualityPreset = .maximum
            selectedVoiceExportModes = [.combined]

            activeCapturesSystemAudio = capturesSystemAudio
            activeCapturesMicrophone = capturesMicrophone
            cameraFailureDuringCountdown = nil

            let outputURL = try makeOutputURL()
            let targetProcessID = mode == .browser ? selectedBrowserWindow?.processID : nil
            let request = CaptureRequest(
                mode: mode,
                browserWindowID: selectedBrowserWindowID,
                region: mode == .region ? captureRegion : nil,
                focusMask: mode == .region && isFocusMaskEnabled ? focusMask : nil,
                captureCornerStyle: captureRegionCornerStyle,
                appliesSoftCornerVignette: mode == .region && appliesSoftCornerVignette,
                capturesMouseEffects: capturesMouseEffects,
                capturesSystemAudio: capturesSystemAudio,
                capturesMicrophone: capturesMicrophone,
                outputURL: outputURL,
                cameraOverlay: capturesCamera ? cameraSettings : nil
            )

            phase = .countdown
            windowCoordinator.prepareForCountdown(targetProcessID: targetProcessID)
            await windowCoordinator.runCountdown(from: 3)
            try await Task.sleep(for: .milliseconds(120))
            if let failure = cameraFailureDuringCountdown {
                throw CaptureError.couldNotStartWriter(failure)
            }
            try await captureService.start(request, cameraFrames: capturesCamera ? cameraService.frames : nil)
            if let failure = cameraFailureDuringCountdown {
                let outcome = try await captureService.stop()
                await releaseCamera()
                completionNote = "摄像头已停止，已保留录到的内容。\(failure)"
                applyStopOutcome(outcome)
                windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
                windowCoordinator.showMainWindow()
                return
            }

            phase = .recording
            beginElapsedTimer()
            windowCoordinator.showRecordingHUD()
            windowCoordinator.updateGlobalShortcuts(
                isRegionPreparing: false,
                isRegionLocked: false,
                isRecording: true
            )
        } catch {
            await releaseCamera()
            stopElapsedTimer()
            windowCoordinator.hideRecordingHUD()
            windowCoordinator.showMainWindow()
            if isScreenCapturePermissionFailure(error) {
                phase = .idle
                errorMessage = nil
                enterScreenCapturePermissionState()
            } else {
                phase = .failed
                errorMessage = error.localizedDescription
                recoveryURLs = captureService.recoveryURLs
                hasRetryableSave = captureService.hasRetryableAutomaticSave
            }
            if mode == .region {
                isRegionSelectionLocked = windowCoordinator.setRegionSelectionLocked(false)
                windowCoordinator.updateGlobalShortcuts(
                    isRegionPreparing: false,
                    isRegionLocked: false,
                    isRecording: false
                )
            }
        }
    }

    private func isScreenCapturePermissionFailure(_ error: Error) -> Bool {
        if let captureError = error as? CaptureError,
           case .permissionRequired = captureError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.Code.userDeclined.rawValue
    }

    private func enterScreenCapturePermissionState() {
        permissionGranted = false
        hasRequestedPermission = true
        browserListError = nil
        isRegionSelectionLocked = false
        windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
        windowCoordinator.updateGlobalShortcuts(
            isRegionPreparing: false,
            isRegionLocked: false,
            isRecording: false
        )
    }

    private func pauseRecording() async {
        guard phase == .recording else { return }
        await captureService.pause()
        freezeElapsedTime()
        phase = .paused
    }

    private func resumeRecording() async {
        guard phase == .paused else { return }
        await captureService.resume()
        activeRecordingBeganAt = Date()
        phase = .recording
    }

    private func performStopRecording() async {
        guard phase.isCapturing else { return }
        windowCoordinator.updateGlobalShortcuts(
            isRegionPreparing: false,
            isRegionLocked: false,
            isRecording: false
        )
        freezeElapsedTime()
        stopElapsedTimer()
        phase = .preparingExport
        windowCoordinator.hideRecordingHUD()
        windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
        windowCoordinator.showMainWindow()

        do {
            let outcome = try await captureService.stop()
            await releaseCamera()
            applyStopOutcome(outcome)
        } catch {
            await releaseCamera()
            errorMessage = error.localizedDescription
            hasRetryableSave = captureService.hasRetryableAutomaticSave
            recoveryURLs = captureService.recoveryURLs
            phase = .failed
        }
        windowCoordinator.showMainWindow()
    }

    private func handleUnexpectedStop(_ error: Error) async {
        guard phase.isCapturing, !isHandlingUnexpectedStop else { return }
        isHandlingUnexpectedStop = true
        defer { isHandlingUnexpectedStop = false }

        windowCoordinator.updateGlobalShortcuts(
            isRegionPreparing: false,
            isRegionLocked: false,
            isRecording: false
        )

        freezeElapsedTime()
        stopElapsedTimer()
        phase = .preparingExport
        windowCoordinator.hideRecordingHUD()
        windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
        windowCoordinator.showMainWindow()

        do {
            completionNote = "录制来源已停止，已尽力保存此前内容。\(error.localizedDescription)"
            let outcome = try await captureService.stop()
            await releaseCamera()
            applyStopOutcome(outcome)
        } catch {
            await releaseCamera()
            errorMessage = CaptureError.streamStopped(error.localizedDescription).localizedDescription
            hasRetryableSave = captureService.hasRetryableAutomaticSave
            recoveryURLs = captureService.recoveryURLs
            phase = .failed
        }
        windowCoordinator.showMainWindow()
    }

    private func applyStopOutcome(_ outcome: CaptureStopOutcome) {
        switch outcome {
        case .exported(let result):
            lastRecordingResult = result
            phase = .finished
        case .awaitingExportChoice:
            selectedQualityPreset = .maximum
            selectedVoiceExportModes = [.combined]
            phase = .choosingExport
        }
    }

    private func performExport(
        qualityPreset: RecordingQualityPreset,
        modes: Set<VoiceExportMode>
    ) async {
        guard phase == .exporting,
              !activeCapturesMicrophone || !modes.isEmpty else { return }

        do {
            let result = try await captureService.exportPendingRecording(
                qualityPreset: qualityPreset,
                modes: modes
            )
            lastRecordingResult = result
            recoveryURLs = []
            phase = .finished
        } catch {
            errorMessage = error.localizedDescription
            recoveryURLs = captureService.recoveryURLs
            phase = .choosingExport
        }
    }

    private func performRetrySaving() async {
        guard phase == .failed, hasRetryableSave else { return }
        errorMessage = nil
        phase = .exporting

        do {
            let result = try captureService.retryPendingAutomaticSave()
            lastRecordingResult = result
            hasRetryableSave = false
            recoveryURLs = []
            phase = .finished
        } catch {
            errorMessage = error.localizedDescription
            hasRetryableSave = captureService.hasRetryableAutomaticSave
            recoveryURLs = captureService.recoveryURLs
            phase = .failed
        }
    }

    private func beginElapsedTimer() {
        elapsedBeforeCurrentSegment = 0
        elapsedTime = 0
        activeRecordingBeganAt = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateElapsedTime()
            }
        }
    }

    private func updateElapsedTime() {
        guard let activeRecordingBeganAt else {
            elapsedTime = elapsedBeforeCurrentSegment
            return
        }
        elapsedTime = elapsedBeforeCurrentSegment + Date().timeIntervalSince(activeRecordingBeganAt)
    }

    private func freezeElapsedTime() {
        guard let activeRecordingBeganAt else { return }
        elapsedBeforeCurrentSegment += Date().timeIntervalSince(activeRecordingBeganAt)
        self.activeRecordingBeganAt = nil
        elapsedTime = elapsedBeforeCurrentSegment
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        activeRecordingBeganAt = nil
    }

    private func makeOutputURL() throws -> URL {
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(
            at: downloads,
            withIntermediateDirectories: true
        )
        let initialURL = downloads.appendingPathComponent(TimeFormatting.outputFilename())
        var candidate = initialURL
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path)
            || FileManager.default.fileExists(
                atPath: TimeFormatting.voiceOutputURL(matching: candidate).path
            ) {
            let stem = initialURL.deletingPathExtension().lastPathComponent
            candidate = downloads
                .appendingPathComponent("\(stem) (\(index))")
                .appendingPathExtension("mp4")
            index += 1
        }
        return candidate
    }

    private func ensureDiskSpace() throws {
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        let values = try downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < 5_000_000_000 {
            throw CaptureError.insufficientDiskSpace
        }
    }
}
