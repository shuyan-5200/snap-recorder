import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: CaptureMode = .window
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
    @Published var availableWindows: [CaptureWindowInfo] = []
    @Published var selectedWindowID: CGWindowID?
    @Published private(set) var availableDisplays: [CaptureDisplayInfo] = []
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?
    @Published private(set) var displayThumbnail: CGImage?
    @Published private(set) var isLoadingDisplays = false
    @Published private(set) var isLoadingDisplayThumbnail = false
    @Published private(set) var displayListError: String?
    @Published private(set) var displayPreviewError: String?
    private var hasLoadedDisplays = false
    private var displayPreviewTask: Task<Void, Never>?
    private var previewDisplayID: CGDirectDisplayID?
    private var displayPreviewGeneration = UUID()
    @Published var phase: RecordingPhase = .idle
    @Published var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published var hasRequestedPermission = false
    @Published var isLoadingWindows = false
    @Published var windowSelectionNote: String?
    @Published var windowListError: String?
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
    @Published var selectedExportTracks: Set<RecordingTrack> = [.video]
    @Published var selectedExportArrangement: ExportArrangement = .merged

    @Published var exportName = ""
    @Published var customSizeMegabytes = "20"
    @Published var exportInfo: RecordingExportInfo?
    @Published var isCancellingExport = false
    private var exportTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var activeCapturesCamera = false

    private let captureService: ScreenCaptureService
    private unowned let windowCoordinator: WindowCoordinator
    private var elapsedTimer: Timer?
    private var activeRecordingBeganAt: Date?
    private var elapsedBeforeCurrentSegment: TimeInterval = 0
    private var isHandlingUnexpectedStop = false
    private var hasLoadedWindows = false
    private var awaitingAccessibilityWindowID: CGWindowID?
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

    var selectedWindow: CaptureWindowInfo? {
        guard let selectedWindowID else { return nil }
        return availableWindows.first { $0.id == selectedWindowID }
    }

    var selectedDisplay: CaptureDisplayInfo? {
        availableDisplays.first { $0.id == selectedDisplayID }
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
        if mode == .window {
            return selectedWindow != nil
        }
        if mode == .region {
            return captureRegion != nil
        }
        return selectedDisplay != nil && !isLoadingDisplays
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

    var isExportWorkspace: Bool { phase == .choosingExport || phase == .finished }

    var hasUnfinishedSave: Bool {
        (captureService.hasPendingRecording && lastOutputURLs.isEmpty) || hasRetryableSave
    }

    var exportButtonTitle: String {
        lastOutputURLs.isEmpty ? "保存到下载" : "再导出一份"
    }

    var currentExportPlan: VideoExportPlan? {
        guard let exportInfo, exportSelection.includesVideo else { return nil }
        return try? ExportPlanning.plan(
            sourceSize: exportInfo.size, duration: exportInfo.duration,
            preset: selectedQualityPreset, customMegabytes: Double(customSizeMegabytes),
            hasSystemAudio: exportSelection.includesSystemInVideo,
            sourceVideoBitrate: exportInfo.sourceVideoBitrate, sourceFrameRate: exportInfo.sourceFrameRate,
            sourceBytes: exportInfo.sourceBytes,
            includesCombinedVoice: exportSelection.includesVoiceInVideo
        )
    }

    var exportValidationMessage: String? {
        do {
            _ = try ExportPlanning.validatedName(exportName, fallback: "录屏")
            if let exportInfo {
                try exportSelection.validate(available: exportInfo.availableTracks)
                if exportSelection.includesVideo {
                    _ = try ExportPlanning.plan(
                        sourceSize: exportInfo.size, duration: exportInfo.duration,
                        preset: selectedQualityPreset, customMegabytes: Double(customSizeMegabytes),
                        hasSystemAudio: exportSelection.includesSystemInVideo,
                        sourceVideoBitrate: exportInfo.sourceVideoBitrate, sourceFrameRate: exportInfo.sourceFrameRate,
                        sourceBytes: exportInfo.sourceBytes,
                        includesCombinedVoice: exportSelection.includesVoiceInVideo
                    )
                }
            }
            return nil
        } catch { return error.localizedDescription.replacingOccurrences(of: "视频保存失败：", with: "") }
    }

    var canExport: Bool {
        isExportWorkspace && exportInfo != nil && exportValidationMessage == nil
    }

    var customSizeGuidance: String {
        guard let info = exportInfo, exportSelection.includesVideo,
              let range = try? ExportPlanning.customSizeRecommendation(
                sourceSize: info.size, duration: info.duration,
                hasSystemAudio: exportSelection.includesSystemInVideo,
                sourceVideoBitrate: info.sourceVideoBitrate, sourceBytes: info.sourceBytes,
                includesCombinedVoice: exportSelection.includesVoiceInVideo
              ) else { return "" }
        return String(format: "建议 %.1f–%.1f MB · 最小值按“极小”档预算计算",
                      range.minimum, range.suggestedMaximum)
    }

    var exportEstimate: String {
        guard let info = exportInfo, let plan = currentExportPlan else { return "" }
        let size = "\(Int(plan.size.width)) × \(Int(plan.size.height)) · \(plan.frameRate) 帧"
        if let limit = plan.byteLimit {
            return "最高 \(size) · 每个视频 ≤ \(ExportPlanning.sizeText(Double(limit)))"
        }
        let estimate = plan.estimatedBytesPerSecond * info.duration
        if selectedQualityPreset == .maximum {
            let voiceBytes = !exportSelection.includesSystemInVideo && exportSelection.includesVoiceInVideo
                ? Double(plan.audioBitrate) / 8 * info.duration : 0
            let upper = Double(info.sourceBytes) + voiceBytes
            let lower = min(upper, estimate)
            let text = upper - lower > 100_000
                ? "\(ExportPlanning.sizeText(lower))–\(ExportPlanning.sizeText(upper))"
                : ExportPlanning.sizeText(upper)
            return "\(size) · 视频约 \(text)"
        }
        return "\(size) · 视频约 \(ExportPlanning.sizeText(estimate))"
    }

    /// A generated fixture exercises the real export screen without capturing private media.
    func prepareExportPreview() async {
        guard RecordingDiagnostics.isExportPreview else { return }
        if CommandLine.arguments.contains("--preview-region") {
            mode = .region
        }
        phase = .preparingExport
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapRecorder-UI-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let video = directory.appendingPathComponent("source.mp4")
            let voice = directory.appendingPathComponent("microphone.m4a")
            let system = directory.appendingPathComponent("system.m4a")
            let videoWithAudio = directory.appendingPathComponent("source-audio.mp4")
            try await ExportDiagnostics.makeFixture(at: video, seconds: 2)
            try ExportDiagnostics.makeToneFile(at: voice, frequency: 880, seconds: 2)
            try ExportDiagnostics.makeToneFile(at: system, frequency: 440, seconds: 2)
            try await RecordingExporter.combine(videoURL: video, microphoneURL: system, outputURL: videoWithAudio)
            try FileManager.default.removeItem(at: video)
            try FileManager.default.removeItem(at: system)
            try captureService.installPendingRecordingForSelfTest(
                videoURL: videoWithAudio, microphoneURL: voice,
                finalVideoURL: directory.appendingPathComponent("导出界面测试.mp4")
            )
            activeCapturesMicrophone = true
            activeCapturesSystemAudio = true
            exportName = "导出界面测试"
            await applyStopOutcome(.awaitingExportChoice)
            windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
            windowCoordinator.showMainWindow()
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
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
            Task { await refreshWindows() }
            captureModeDidChange(mode)
        }
    }

    func recheckPermission() {
        let nowGranted = CGPreflightScreenCaptureAccess()
        permissionGranted = nowGranted
        if !nowGranted {
            updateDisplayPreview()
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
            Task { await refreshWindows() }
            if mode == .display { Task { await refreshDisplays() } }
        }
        if nowGranted, mode == .region, phase == .idle {
            captureModeDidChange(.region)
        }
        if nowGranted, mode == .window, phase == .idle,
           let awaitingAccessibilityWindowID,
           awaitingAccessibilityWindowID == selectedWindowID,
           windowCoordinator.hasAccessibilityPermission {
            // Returning from System Settings after authorization should finish
            // the user's original selection; do not make them choose it again.
            selectedWindowDidChange(bringsTargetForward: true)
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

    func prepareDrawerVisibilityChange(width: CGFloat, side: RecorderDrawerSide, animated: Bool) {
        windowCoordinator.resizeMainWindowForDrawer(width: width, side: side, animated: animated)
    }

    func closeExportDrawer() {
        guard isExportWorkspace, closeExportSessionIfNeeded() else { return }
        restoreSourceAfterExport()
    }

    func closeExportSessionIfNeeded() -> Bool {
        guard isExportWorkspace else { return true }
        if hasUnfinishedSave {
            let alert = NSAlert()
            alert.messageText = "录制还没有保存"
            alert.informativeText = "放弃后可在废纸篓中找回临时原片。"
            alert.addButton(withTitle: "继续导出")
            alert.addButton(withTitle: "放弃此次录制")
            guard windowCoordinator.runAlert(alert) == .alertSecondButtonReturn else { return false }
        }
        return endExportSession()
    }

    func mainWindowClosed() {
        stopDisplayPreview()
        if phase == .idle || phase == .failed || phase == .finished || phase == .choosingExport {
            setCameraCaptureEnabled(false)
            windowCoordinator.hideWindowSelection()
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
        updateDisplayPreview()
        guard permissionGranted else {
            isRegionSelectionLocked = false
            windowCoordinator.hideWindowSelection()
            windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
            windowCoordinator.updateGlobalShortcuts(
                isRegionPreparing: false,
                isRegionLocked: false,
                isRecording: false
            )
            return
        }
        if newMode == .window {
            windowCoordinator.hideRegionSelection(resetMainWindowLevel: true)
            selectedWindowDidChange()
        } else {
            windowCoordinator.hideWindowSelection()
        }
        if newMode == .display { Task { await refreshDisplays() } }
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

    func selectWindow(_ windowID: CGWindowID) {
        awaitingAccessibilityWindowID = nil
        windowSelectionNote = nil
        selectedWindowID = windowID
        selectedWindowDidChange(
            requestAccessibilityPermission: true,
            bringsTargetForward: true
        )
    }

    func selectedWindowDidChange(
        requestAccessibilityPermission: Bool = false,
        bringsTargetForward: Bool = false
    ) {
        if awaitingAccessibilityWindowID == nil {
            windowSelectionNote = nil
        }
        guard permissionGranted, mode == .window, phase == .idle,
              let selectedWindow else {
            windowCoordinator.hideWindowSelection()
            return
        }
        let hasSiblingWindows = availableWindows.lazy
            .filter { $0.processID == selectedWindow.processID }
            .prefix(2)
            .count > 1
        let raisedExactly = windowCoordinator.showWindowSelection(
            selectedWindow,
            requiresExactRaise: hasSiblingWindows,
            requestAccessibilityPermission: requestAccessibilityPermission,
            bringsTargetForward: bringsTargetForward
        )
        if hasSiblingWindows, !raisedExactly, requestAccessibilityPermission {
            awaitingAccessibilityWindowID = selectedWindow.id
            windowSelectionNote = "请在已打开的“辅助功能”中允许 Snap Recorder；返回后会自动置顶所选窗口。"
        } else if bringsTargetForward, raisedExactly {
            awaitingAccessibilityWindowID = nil
            windowSelectionNote = nil
        }
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

    func refreshWindows() async {
        guard permissionGranted, !isLoadingWindows else { return }
        isLoadingWindows = true
        windowListError = nil
        defer { isLoadingWindows = false }

        do {
            let windows = try await captureService.availableWindows()
            let previousSelection = selectedWindowID
            availableWindows = windows

            if let previousSelection,
               windows.contains(where: { $0.id == previousSelection }) {
                windowSelectionNote = nil
                hasLoadedWindows = true
                selectedWindowDidChange()
                return
            }

            if !hasLoadedWindows {
                selectedWindowID = windowCoordinator.frontmostCaptureWindowID(in: windows)
                windowSelectionNote = nil
            } else if previousSelection != nil {
                awaitingAccessibilityWindowID = nil
                selectedWindowID = nil
                windowSelectionNote = windows.isEmpty
                    ? nil
                    : "之前选择的窗口已关闭，请重新选择。"
            }
            hasLoadedWindows = true
            selectedWindowDidChange()
        } catch {
            if isScreenCapturePermissionFailure(error) {
                enterScreenCapturePermissionState()
            } else {
                windowListError = error.localizedDescription
            }
        }
    }

    func refreshDisplays(userInitiated: Bool = false) async {
        guard permissionGranted, !isLoadingDisplays else { return }
        isLoadingDisplays = true
        displayListError = nil
        defer { isLoadingDisplays = false }
        do {
            let displays = try await captureService.availableDisplays()
            guard permissionGranted else { return }
            let previous = selectedDisplayID
            availableDisplays = displays
            if !hasLoadedDisplays || previous != nil {
                selectedDisplayID = DisplaySelection.resolve(current: previous, available: displays,
                    preferred: windowCoordinator.mainWindowDisplayID)
            }
            // A disconnected target never changes silently. Explicit Refresh
            // can select the sole remaining display, whose number rail is hidden.
            if userInitiated, selectedDisplayID == nil, displays.count == 1 {
                selectedDisplayID = displays.first?.id
            }
            hasLoadedDisplays = true
            if previous != nil, selectedDisplayID == nil {
                displayListError = "之前选择的屏幕已断开 请重新选择"
            } else if displays.isEmpty {
                displayListError = "没有找到可录制的本地屏幕"
            }
            updateDisplayPreview()
        } catch {
            if isScreenCapturePermissionFailure(error) {
                enterScreenCapturePermissionState()
            } else {
                displayListError = error.localizedDescription
            }
        }
    }

    func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard phase == .idle || phase == .failed,
              availableDisplays.contains(where: { $0.id == displayID }) else { return }
        selectedDisplayID = displayID
        displayListError = nil
        updateDisplayPreview()
    }

    func updateDisplayPreview() {
        guard permissionGranted, mode == .display, phase == .idle || phase == .failed,
              let selectedDisplayID, selectedDisplay != nil else {
            stopDisplayPreview()
            return
        }
        guard previewDisplayID != selectedDisplayID || displayPreviewTask == nil else { return }
        stopDisplayPreview()
        previewDisplayID = selectedDisplayID
        let generation = displayPreviewGeneration
        isLoadingDisplayThumbnail = true
        displayPreviewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let image = try await self.captureService.displayThumbnail(displayID: selectedDisplayID)
                    guard !Task.isCancelled, self.displayPreviewGeneration == generation else { return }
                    self.displayThumbnail = image
                    self.displayPreviewError = nil
                    self.isLoadingDisplayThumbnail = false
                } catch {
                    guard !Task.isCancelled, self.displayPreviewGeneration == generation else { return }
                    self.displayThumbnail = nil
                    self.isLoadingDisplayThumbnail = false
                    self.displayPreviewError = "缩略图暂不可用 可点击刷新"
                    if self.isScreenCapturePermissionFailure(error) {
                        self.enterScreenCapturePermissionState()
                        return
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private func stopDisplayPreview() {
        displayPreviewTask?.cancel()
        displayPreviewTask = nil
        previewDisplayID = nil
        displayPreviewGeneration = UUID()
        displayThumbnail = nil
        displayPreviewError = nil
        isLoadingDisplayThumbnail = false
    }

    func startRecording() {
        guard recordingStartTask == nil else { return }
        recordingStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.recordingStartTask = nil }
            await self.performStartRecording()
        }
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
        if phase == .countdown {
            recordingStartTask?.cancel()
            return
        }
        Task { await performStopRecording() }
    }

    var exportSelection: RecordingExportSelection {
        RecordingExportSelection(tracks: selectedExportTracks, arrangement: selectedExportArrangement)
    }

    func toggleExportTrack(_ track: RecordingTrack) {
        guard isExportWorkspace, exportInfo?.availableTracks.contains(track) == true else { return }
        if selectedExportTracks.contains(track) { selectedExportTracks.remove(track) }
        else { selectedExportTracks.insert(track) }
        errorMessage = nil
    }

    func exportRecording() {
        guard canExport else { return }
        let preset = selectedQualityPreset
        let selection = exportSelection
        let name = exportName
        let megabytes = Double(customSizeMegabytes)
        errorMessage = nil
        isCancellingExport = false
        phase = .exporting
        exportTask = Task {
            await performExport(qualityPreset: preset, selection: selection, name: name, customMegabytes: megabytes)
        }
    }

    func cancelExport() {
        guard phase == .exporting else { return }
        isCancellingExport = true
        exportTask?.cancel()
    }

    func retrySavingRecording() {
        Task { await performRetrySaving() }
    }

    @discardableResult
    func endExportSession() -> Bool {
        guard phase != .exporting, phase != .preparingExport, phase != .countdown, !phase.isCapturing else { return false }
        do {
            try captureService.discardPendingRecording(moveToTrash: lastOutputURLs.isEmpty)
        } catch {
            errorMessage = "临时录制未能清理：\(error.localizedDescription)"
            return false
        }
        completionNote = nil
        errorMessage = nil
        lastRecordingResult = nil
        hasRetryableSave = false
        recoveryURLs = []
        exportInfo = nil
        selectedQualityPreset = .maximum
        selectedExportTracks = [.video]
        selectedExportArrangement = .merged
        isRegionSelectionLocked = false
        phase = .idle
        return true
    }

    func recordAgain() {
        guard endExportSession() else { return }
        restoreSourceAfterExport()
    }

    private func restoreSourceAfterExport() {
        if mode == .window {
            Task { await refreshWindows() }
        } else if mode == .region {
            captureModeDidChange(.region)
        }
    }

    func restartRecording() {
        let restoreCamera = activeCapturesCamera
        guard isExportWorkspace, closeExportSessionIfNeeded() else { return }
        Task {
            if mode == .window { await refreshWindows() }
            if mode == .region { captureModeDidChange(.region) }
            if restoreCamera {
                setCameraCaptureEnabled(true)
                await cameraOperation?.value
            }
            await performStartRecording()
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
        let previousPhase = phase
        let previousRegionLock = isRegionSelectionLocked

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
            cameraFailureDuringCountdown = nil

            let outputURL = try makeOutputURL()
            // Snapshot the selected title before countdown/refresh can change it.
            let recordingWindow = mode == .window ? selectedWindow : nil
            let defaultExportName = ExportPlanning.recordingName(
                windowTitle: recordingWindow?.title,
                fallback: outputURL.deletingPathExtension().lastPathComponent
            )
            let targetProcessID = recordingWindow?.processID
            let request = CaptureRequest(
                mode: mode,
                windowID: selectedWindowID,
                displayID: mode == .display ? selectedDisplayID : nil,
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
            updateDisplayPreview()
            windowCoordinator.updateGlobalShortcuts(
                isRegionPreparing: false,
                isRegionLocked: false,
                isCountdownActive: true,
                isRecording: false
            )
            // Resolve the main panel before hiding it; keep this window identity
            // as the sole exception to the application's capture exclusion.
            let mainPanel = mode == .window ? nil : try await captureService.capturableMainWindow(
                windowID: windowCoordinator.mainWindowID
            )
            windowCoordinator.prepareForCountdown(targetProcessID: targetProcessID)
            try await windowCoordinator.runCountdown(from: 3)
            try await Task.sleep(for: .milliseconds(120))
            try Task.checkCancellation()
            if let failure = cameraFailureDuringCountdown {
                throw CaptureError.couldNotStartWriter(failure)
            }

            errorMessage = nil
            completionNote = nil
            lastRecordingResult = nil
            hasRetryableSave = false
            recoveryURLs = []
            selectedQualityPreset = .maximum
            selectedExportTracks = [.video]
            selectedExportArrangement = .merged
            exportName = defaultExportName
            activeCapturesCamera = capturesCamera
            activeCapturesSystemAudio = capturesSystemAudio
            activeCapturesMicrophone = capturesMicrophone

            try await captureService.start(request, cameraFrames: capturesCamera ? cameraService.frames : nil, mainPanel: mainPanel)
            if let failure = cameraFailureDuringCountdown {
                let outcome = try await captureService.stop()
                await releaseCamera()
                completionNote = "摄像头已停止，已保留录到的内容。\(failure)"
                await applyStopOutcome(outcome)
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
        } catch is CancellationError {
            cameraFailureDuringCountdown = nil
            phase = previousPhase
            stopElapsedTimer()
            windowCoordinator.hideRecordingHUD()
            if mode == .region {
                isRegionSelectionLocked = windowCoordinator.setRegionSelectionLocked(previousRegionLock)
            }
            windowCoordinator.showMainWindow()
            if mode == .window { selectedWindowDidChange() }
            windowCoordinator.updateGlobalShortcuts(
                isRegionPreparing: mode == .region && previousPhase == .idle,
                isRegionLocked: mode == .region && previousRegionLock,
                isRecording: false
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
        stopDisplayPreview()
        hasRequestedPermission = true
        windowListError = nil
        windowCoordinator.hideWindowSelection()
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
            await applyStopOutcome(outcome)
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
            await applyStopOutcome(outcome)
        } catch {
            await releaseCamera()
            errorMessage = CaptureError.streamStopped(error.localizedDescription).localizedDescription
            hasRetryableSave = captureService.hasRetryableAutomaticSave
            recoveryURLs = captureService.recoveryURLs
            phase = .failed
        }
        windowCoordinator.showMainWindow()
    }

    private func applyStopOutcome(_ outcome: CaptureStopOutcome) async {
        switch outcome {
        case .exported(let result):
            lastRecordingResult = result
            phase = .finished
        case .awaitingExportChoice:
            selectedQualityPreset = .maximum
            selectedExportTracks = [.video]
            selectedExportArrangement = .merged
            do {
                exportInfo = try await captureService.pendingExportInfo()
                selectedExportTracks = exportInfo?.availableTracks ?? [.video]
                selectedExportArrangement = selectedExportTracks.contains(.voice) ? .separate : .merged
                if let exportInfo,
                   let range = try? ExportPlanning.customSizeRecommendation(
                    sourceSize: exportInfo.size, duration: exportInfo.duration,
                    hasSystemAudio: exportSelection.includesSystemInVideo,
                    sourceVideoBitrate: exportInfo.sourceVideoBitrate, sourceBytes: exportInfo.sourceBytes,
                    includesCombinedVoice: exportSelection.includesVoiceInVideo
                   ) {
                    customSizeMegabytes = String(format: "%.1f", range.suggestedMaximum)
                }
            }
            catch { errorMessage = error.localizedDescription }
            phase = .choosingExport
        }
    }

    private func performExport(
        qualityPreset: RecordingQualityPreset,
        selection: RecordingExportSelection,
        name: String,
        customMegabytes: Double?
    ) async {
        guard phase == .exporting else { return }

        do {
            let result = try await captureService.exportPendingRecording(
                qualityPreset: qualityPreset,
                selection: selection,
                name: name,
                customMegabytes: customMegabytes
            )
            lastRecordingResult = RecordingResult(urls: lastOutputURLs + result.urls)
            recoveryURLs = []
            phase = .finished
        } catch {
            errorMessage = error is CancellationError ? nil : error.localizedDescription
            recoveryURLs = captureService.recoveryURLs
            phase = lastOutputURLs.isEmpty ? .choosingExport : .finished
        }
        isCancellingExport = false
        exportTask = nil
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
