import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var mainWindow: NSWindow?
    private var countdownPanel: NSPanel?
    private var recordingPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private let regionOverlay = CaptureRegionOverlayController()
    private var shortcutController: GlobalShortcutController?
    private let cameraPreview = CameraPreviewController()

    init(initialExternalApplication: NSRunningApplication?) {
        lastExternalApplication = initialExternalApplication
        super.init()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            Task { @MainActor [weak self] in
                self?.lastExternalApplication = application
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func attach(model: AppModel) {
        self.model = model
        shortcutController = GlobalShortcutController(
            toggleOverlay: { [weak model] in
                Task { @MainActor in model?.toggleRegionSelectionLock() }
            },
            startRecording: { [weak model] in
                Task { @MainActor in model?.startRecordingFromShortcut() }
            },
            stopRecording: { [weak model] in
                Task { @MainActor in model?.stopRecording() }
            }
        )
        createStatusItemIfNeeded()
    }

    func showMainWindow() {
        guard let model else { return }
        let window: NSWindow

        if let mainWindow {
            window = mainWindow
        } else {
            let created = Self.makeMainWindow()
            created.delegate = self
            created.contentViewController = NSHostingController(
                rootView: RecorderView(model: model)
            )
            created.center()
            mainWindow = created
            window = created
        }

        statusItem?.isVisible = true
        window.level = model.mode == .region ? .screenSaver : .normal
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Also used by the camera-free pointer-interaction test harness.
    static func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Snap Recorder"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // SwiftUI controls can leave mouse-down handling to a drag gesture.
        // Background window dragging steals that sequence before the slider
        // starts tracking. Only the native title bar may initiate window moves.
        window.isMovableByWindowBackground = false
        window.isMovable = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.sharingType = .none
        return window
    }

    @discardableResult
    func showRegionSelection(
        aspectRatio: CaptureAspectRatio,
        captureCornerStyle: FocusMaskCornerStyle,
        focusMaskEnabled: Bool,
        focusMaskCornerStyle: FocusMaskCornerStyle,
        interactionLocked: Bool,
        selectionChanged: @escaping (CaptureRegion) -> Void,
        focusMaskChanged: @escaping (CaptureFocusMask?) -> Void
    ) -> CaptureRegion? {
        mainWindow?.level = .screenSaver
        return regionOverlay.show(
            aspectRatio: aspectRatio,
            captureCornerStyle: captureCornerStyle,
            focusMaskEnabled: focusMaskEnabled,
            focusMaskCornerStyle: focusMaskCornerStyle,
            interactionLocked: interactionLocked,
            selectionChanged: selectionChanged,
            focusMaskChanged: focusMaskChanged
        )
    }

    @discardableResult
    func updateRegionAspectRatio(_ aspectRatio: CaptureAspectRatio) -> CaptureRegion? {
        regionOverlay.update(aspectRatio: aspectRatio)
    }

    @discardableResult
    func setRegionFocusMaskEnabled(_ enabled: Bool) -> CaptureFocusMask? {
        regionOverlay.setFocusMaskEnabled(enabled)
    }

    @discardableResult
    func setRegionFocusMaskCornerStyle(_ style: FocusMaskCornerStyle) -> CaptureFocusMask? {
        regionOverlay.setFocusMaskCornerStyle(style)
    }

    func setRegionCaptureCornerStyle(_ style: FocusMaskCornerStyle) {
        regionOverlay.setCaptureCornerStyle(style)
    }

    @discardableResult
    func setRegionSelectionLocked(_ locked: Bool) -> Bool {
        regionOverlay.setInteractionLocked(locked)
    }

    @discardableResult
    func toggleRegionSelectionLocked() -> Bool {
        regionOverlay.toggleInteractionLocked()
    }

    func updateGlobalShortcuts(
        isRegionPreparing: Bool,
        isRegionLocked: Bool,
        isRecording: Bool
    ) {
        shortcutController?.update(
            isRegionPreparing: isRegionPreparing,
            isRegionLocked: isRegionLocked,
            isRecording: isRecording
        )
    }

    func hideRegionSelection(resetMainWindowLevel: Bool = false) {
        regionOverlay.hide()
        if resetMainWindowLevel {
            mainWindow?.level = .normal
        }
    }

    func prepareForCountdown(targetProcessID: pid_t?) {
        mainWindow?.orderOut(nil)
        statusItem?.isVisible = false

        let targetApplication = targetProcessID.flatMap(NSRunningApplication.init(processIdentifier:))
            ?? lastExternalApplication
        targetApplication?.activate(options: [.activateAllWindows])
    }

    func runCountdown(from start: Int) async {
        let panel = countdownPanel ?? makeCountdownPanel()
        countdownPanel = panel
        position(panel: panel, size: CGSize(width: 174, height: 174), topOffset: nil)

        for number in stride(from: start, through: 1, by: -1) {
            panel.contentView = NSHostingView(rootView: CountdownView(number: number))
            panel.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
    }

    func showRecordingHUD() {
        guard let model else { return }
        let panel: NSPanel

        if let recordingPanel {
            panel = recordingPanel
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 274, height: 54),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.level = .screenSaver
            created.isFloatingPanel = true
            created.hidesOnDeactivate = false
            created.becomesKeyOnlyIfNeeded = true
            created.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle
            ]
            created.backgroundColor = .clear
            created.isOpaque = false
            created.hasShadow = true
            created.sharingType = .none
            created.contentView = NSHostingView(rootView: RecordingHUDView(model: model))
            recordingPanel = created
            panel = created
        }

        position(panel: panel, size: CGSize(width: 274, height: 54), topOffset: 18)
        panel.orderFrontRegardless()
    }

    func hideRecordingHUD() {
        recordingPanel?.orderOut(nil)
    }

    func showCameraPreview(frames: CameraFrameStore, settings: CameraOverlaySettings) {
        cameraPreview.show(frames: frames, settings: settings)
    }

    func hideCameraPreview() {
        cameraPreview.hide()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow {
            model?.mainWindowClosed()
        }
    }

    private func makeCountdownPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 174, height: 174),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        return panel
    }

    private func position(panel: NSPanel, size: CGSize, topOffset: CGFloat?) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame = screen.visibleFrame
        let origin: CGPoint

        if let topOffset {
            origin = CGPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - topOffset
            )
        } else {
            origin = CGPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            )
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func createStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "Snap Recorder 录屏"
        )

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开 Snap Recorder",
            action: #selector(openSnapRecorder),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 Snap Recorder",
            action: #selector(quitSnapRecorder),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func openSnapRecorder() {
        showMainWindow()
    }

    @objc private func quitSnapRecorder() {
        NSApp.terminate(nil)
    }
}
