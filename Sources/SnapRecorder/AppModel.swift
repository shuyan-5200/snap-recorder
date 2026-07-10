import AppKit
import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: CaptureMode = .browser
    @Published var capturesSystemAudio = true
    @Published var capturesMicrophone = false
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
    @Published var elapsedTime: TimeInterval = 0
    @Published var lastRecordingResult: RecordingResult?
    @Published var errorMessage: String?
    @Published var completionNote: String?
    @Published var hasRetryableSave = false
    @Published var recoveryURLs: [URL] = []
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
    }

    var selectedBrowserWindow: BrowserWindowInfo? {
        guard let selectedBrowserWindowID else { return nil }
        return browserWindows.first { $0.id == selectedBrowserWindowID }
    }

    var canStartRecording: Bool {
        guard permissionGranted,
              !isRequestingMicrophonePermission,
              phase == .idle || phase == .failed else { return false }
        if capturesMicrophone {
            guard microphoneFeatureAvailable,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                return false
            }
        }
        if mode == .browser {
            return selectedBrowserWindow != nil
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

    var voiceExportButtonTitle: String {
        switch selectedVoiceExportModes {
        case []:
            "请至少选择一种"
        case [.combined]:
            "导出完整视频"
        case [.separate]:
            "导出 2 个分轨文件"
        default:
            "导出全部 3 个文件"
        }
    }

    func requestPermission() {
        hasRequestedPermission = true
        let result = CGRequestScreenCaptureAccess()
        permissionGranted = result || CGPreflightScreenCaptureAccess()

        if permissionGranted {
            Task { await refreshBrowserWindows() }
        }
    }

    func recheckPermission() {
        let nowGranted = CGPreflightScreenCaptureAccess()
        permissionGranted = nowGranted
        if nowGranted,
           phase == .idle || phase == .failed || phase == .finished {
            Task { await refreshBrowserWindows() }
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
            browserListError = error.localizedDescription
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

    func exportVoiceRecording() {
        guard phase == .choosingExport, !selectedVoiceExportModes.isEmpty else { return }
        let modes = selectedVoiceExportModes
        errorMessage = nil
        phase = .exporting
        Task { await performVoiceExport(modes) }
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
        selectedVoiceExportModes = [.combined]
        phase = .idle
        if mode == .browser {
            Task { await refreshBrowserWindows() }
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

        do {
            try ensureDiskSpace()
            errorMessage = nil
            completionNote = nil
            lastRecordingResult = nil
            hasRetryableSave = false
            recoveryURLs = []
            selectedVoiceExportModes = [.combined]

            activeCapturesSystemAudio = capturesSystemAudio
            activeCapturesMicrophone = capturesMicrophone

            let outputURL = try makeOutputURL()
            let targetProcessID = mode == .browser ? selectedBrowserWindow?.processID : nil
            let wallpaperURL = NSScreen.main.flatMap {
                NSWorkspace.shared.desktopImageURL(for: $0)
            }
            let request = CaptureRequest(
                mode: mode,
                browserWindowID: selectedBrowserWindowID,
                capturesSystemAudio: capturesSystemAudio,
                capturesMicrophone: capturesMicrophone,
                outputURL: outputURL,
                wallpaperURL: wallpaperURL
            )

            phase = .countdown
            windowCoordinator.prepareForCountdown(targetProcessID: targetProcessID)
            await windowCoordinator.runCountdown(from: 3)
            try await Task.sleep(for: .milliseconds(120))

            try await captureService.start(request)

            phase = .recording
            beginElapsedTimer()
            windowCoordinator.showRecordingHUD()
        } catch {
            stopElapsedTimer()
            phase = .failed
            errorMessage = error.localizedDescription
            windowCoordinator.hideRecordingHUD()
            windowCoordinator.showMainWindow()
        }
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
        freezeElapsedTime()
        stopElapsedTimer()
        phase = .preparingExport
        windowCoordinator.hideRecordingHUD()
        windowCoordinator.showMainWindow()

        do {
            let outcome = try await captureService.stop()
            applyStopOutcome(outcome)
        } catch {
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

        freezeElapsedTime()
        stopElapsedTimer()
        phase = .preparingExport
        windowCoordinator.hideRecordingHUD()
        windowCoordinator.showMainWindow()

        do {
            completionNote = "录制来源已停止，已尽力保存此前内容。"
            let outcome = try await captureService.stop()
            applyStopOutcome(outcome)
        } catch {
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
            selectedVoiceExportModes = [.combined]
            phase = .choosingExport
        }
    }

    private func performVoiceExport(_ modes: Set<VoiceExportMode>) async {
        guard phase == .exporting, !modes.isEmpty else { return }

        do {
            let result = try await captureService.exportPendingRecording(modes)
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
