import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var mainWindow: NSWindow?
    private var countdownPanels: [CGDirectDisplayID: NSPanel] = [:]
    private var countdownNumber: Int?
    private var recordingPanel: NSPanel?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var rememberedMainDisplayID: CGDirectDisplayID?
    private var screenParametersObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private let regionOverlay = CaptureRegionOverlayController()
    private let windowHighlight = CaptureWindowHighlightController()
    private var windowPresentationGeneration = UUID()
    private var mainWindowResizeTask: Task<Void, Never>?
    private var shortcutController: GlobalShortcutController?
    private let cameraPreview = CameraPreviewController()
    private let countdownSound = CountdownSound()

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
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.model?.mode == .display { await self.model?.refreshDisplays() }
                if let number = self.countdownNumber { self.presentCountdown(number: number) }
                self.model?.updateCameraPreview()
                if let panel = self.recordingPanel, panel.isVisible {
                    self.position(panel: panel, size: panel.frame.size, topOffset: 18)
                }
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
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

    var mainWindowID: CGWindowID? {
        guard let mainWindow, mainWindow.windowNumber > 0 else { return nil }
        return CGWindowID(mainWindow.windowNumber)
    }

    var mainWindowDisplayID: CGDirectDisplayID? {
        presentationScreen.flatMap(ScreenPresentation.displayID)
    }

    private var presentationScreen: NSScreen? {
        mainWindow?.screen
            ?? NSScreen.screens.first { ScreenPresentation.displayID(of: $0) == rememberedMainDisplayID }
            ?? NSScreen.screens.first { ScreenPresentation.displayID(of: $0) == CGMainDisplayID() }
            ?? NSScreen.screens.first
    }

    private func rememberMainScreen() {
        if let screen = mainWindow?.screen { rememberedMainDisplayID = ScreenPresentation.displayID(of: screen) }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        rememberMainScreen()
        model?.updateCameraPreview()
        if let panel = recordingPanel, panel.isVisible {
            position(panel: panel, size: panel.frame.size, topOffset: 18)
        }
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
        restoreInteractiveMainWindowLevel()
        window.ignoresMouseEvents = false
        window.hidesOnDeactivate = false
        // Accessory apps can lose the ordering race when another normal-level
        // app (usually the selected capture target) is still active. LaunchServices
        // can also restore that app after applicationDidFinishLaunching, so
        // confirm the same one-time ordering action on the next run-loop turn.
        bringMainWindowForward(window)
        Self.installTitlebarDragSurface(on: window)
        rememberMainScreen()
        Task { @MainActor [weak self, weak window] in
            // App activation is asynchronous. A short delayed confirmation
            // avoids LaunchServices returning focus to the previously active
            // external app after a cold launch or reopen request.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, let window, self.mainWindow === window,
                  window.isVisible, self.model?.phase != .countdown else { return }
            self.bringMainWindowForward(window)
        }
    }

    private func bringMainWindowForward(_ window: NSWindow) {
        // A deferred launch/reopen must not cover or steal focus from an alert.
        if let modalWindow = NSApp.modalWindow {
            modalWindow.orderFrontRegardless()
            modalWindow.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.activate()
        // The persistent interactive level is managed separately; these calls
        // only make the currently requested main window active and frontmost.
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    func resizeMainWindowForDrawer(width: CGFloat, side: RecorderDrawerSide, animated: Bool) {
        guard let window = mainWindow else { return }
        mainWindowResizeTask?.cancel()
        let initialWidth = window.frame.width
        let expanding = width > initialWidth
        let duration = expanding ? 0.42 : 0.32
        mainWindowResizeTask = Task { @MainActor [weak window] in
            guard let window else { return }
            let began = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                let progress = animated ? min(1, elapsed / duration) : 1
                // Critically damped easing: no bounce, a gentle start and a
                // buffered stop. A reversal starts at the currently drawn size.
                let eased = DrawerMotion.progress(at: progress)
                let nextWidth = initialWidth + (width - initialWidth) * eased
                var frame = window.frame
                let fixedEdge = side == .left ? frame.maxX : frame.minX
                frame.size.width = nextWidth
                frame.origin.x = side == .left ? fixedEdge - nextWidth : fixedEdge
                if let screen = window.screen {
                    frame.origin.x = max(screen.visibleFrame.minX, min(frame.origin.x, screen.visibleFrame.maxX - nextWidth))
                }
                window.setFrame(frame, display: true)
                if progress >= 1 { break }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { break }
            }
        }
    }

    /// Every quit/save guard uses this route: an application-modal alert below
    /// our screen-saver-level panels would swallow input while remaining hidden.
    func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let highestLevel = NSApp.windows
            .filter(\.isVisible)
            .map { $0.level.rawValue }
            .max() ?? NSWindow.Level.floating.rawValue
        let alertLevel = NSWindow.Level(rawValue: max(highestLevel, NSWindow.Level.modalPanel.rawValue) + 1)
        alert.window.level = alertLevel
        alert.window.hidesOnDeactivate = false
        alert.window.sharingType = .none
        alert.layout()
        var placementObserver: NSObjectProtocol?
        var placementTimer: Timer?
        defer {
            placementTimer?.invalidate()
            if let placementObserver { NotificationCenter.default.removeObserver(placementObserver) }
        }
        // Pin both the initial frame and AppKit's deferred modal layout to the
        // main panel's display, even when the capture target is on another one.
        if let screen = presentationScreen {
            let frame = ScreenPresentation.popupFrame(size: alert.window.frame.size,
                near: mainWindow?.isVisible == true ? mainWindow?.frame : nil, in: screen.visibleFrame)
            alert.window.setFrame(frame, display: false)
            placementObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: alert.window, queue: .main
            ) { [weak alert] _ in
                guard let alert else { return }
                alert.window.level = alertLevel
                alert.window.setFrame(frame, display: true)
            }
            // runModal resets the alert to AppKit's modal-panel level after
            // key-window notification. Apply our placement once its modal
            // run loop has begun; the main queue alone does not run here.
            placementTimer = Timer(timeInterval: 0.01, repeats: false) { [weak alert] _ in
                guard let alert else { return }
                alert.window.level = alertLevel
                alert.window.setFrame(frame, display: true)
                alert.window.makeKeyAndOrderFront(nil)
            }
            if let placementTimer { RunLoop.main.add(placementTimer, forMode: .modalPanel) }
        }
        NSApp.activate()
        return alert.runModal()
    }

    /// Also used by the camera-free pointer-interaction test harness.
    static func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 471),
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
        // The main panel is ordinary, shareable content. Auxiliary windows stay
        // excluded by the capture filter, including ones created after capture starts.
        window.sharingType = .readOnly
        return window
    }

    private static func installTitlebarDragSurface(on window: NSWindow) {
        guard let frameView = window.contentView?.superview,
              !frameView.subviews.contains(where: { $0 is TitlebarDragSurface }) else { return }
        let dragSurface = TitlebarDragSurface(frame: .zero)
        // AppKit skips a fully transparent layer in the private title-bar hit
        // hierarchy. A 0.1% neutral fill keeps the hit plane composited while
        // remaining visually indistinguishable from transparent.
        dragSurface.wantsLayer = true
        dragSurface.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.001).cgColor
        frameView.addSubview(dragSurface, positioned: .above, relativeTo: nil)
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
            on: presentationScreen,
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
        isCountdownActive: Bool = false,
        isRecording: Bool
    ) {
        shortcutController?.update(
            isRegionPreparing: isRegionPreparing,
            isRegionLocked: isRegionLocked,
            isCountdownActive: isCountdownActive,
            isRecording: isRecording
        )
    }

    func hideRegionSelection(resetMainWindowLevel: Bool = false) {
        regionOverlay.hide()
        if resetMainWindowLevel {
            restoreInteractiveMainWindowLevel()
        }
    }

    @discardableResult
    func showWindowSelection(
        _ window: CaptureWindowInfo,
        requiresExactRaise: Bool,
        requestAccessibilityPermission: Bool,
        bringsTargetForward: Bool
    ) -> Bool {
        let generation = UUID()
        windowPresentationGeneration = generation
        let canRaiseExactly = !requiresExactRaise || AXIsProcessTrusted()
        if bringsTargetForward, requiresExactRaise, !canRaiseExactly,
           requestAccessibilityPermission {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            Self.openAccessibilitySettings()
        }
        windowHighlight.show(windowID: window.id, fallbackFrame: window.frame)

        // App activation alone cannot choose one window from a multi-window
        // application. Without Accessibility permission it may raise a
        // different Finder (or document) window, so wait for authorization
        // instead of presenting the wrong target.
        if bringsTargetForward, requiresExactRaise, !canRaiseExactly {
            return false
        }

        // Automatic selection and passive refreshes must never change the
        // active application. Otherwise becoming active triggers another
        // refresh, which makes the target and Snap Recorder repeatedly steal
        // focus from one another. Only an explicit menu selection may raise it.
        guard bringsTargetForward else { return canRaiseExactly }

        let targetApplication = NSRunningApplication(processIdentifier: window.processID)
        targetApplication?.activate(options: [.activateAllWindows])

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            if canRaiseExactly, requiresExactRaise {
                _ = Self.raiseWindow(window)
            }
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, self.windowPresentationGeneration == generation,
                  let mainWindow = self.mainWindow,
                  self.model?.mode == .window,
                  self.model?.phase == .idle else { return }
            self.restoreInteractiveMainWindowLevel()
            self.bringMainWindowForward(mainWindow)
        }
        return canRaiseExactly
    }

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    private static func openAccessibilitySettings() {
        let addresses = [
            // Current System Settings extension identifier (verified on macOS 26).
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            // Compatibility fallback for older macOS releases.
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for address in addresses {
            guard let url = URL(string: address) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    /// Picks the topmost recordable window underneath Snap Recorder without
    /// requiring Accessibility permission or activating another application.
    func frontmostCaptureWindowID(in windows: [CaptureWindowInfo]) -> CGWindowID? {
        let candidateIDs = Set(windows.map(\.id))
        guard !candidateIDs.isEmpty,
              let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return windows.first(where: \.isOnScreen)?.id ?? windows.first?.id
        }

        for item in windowList {
            guard let number = item[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)
            if candidateIDs.contains(windowID) { return windowID }
        }

        if let processID = lastExternalApplication?.processIdentifier,
           let matchingWindow = windows.first(where: {
               $0.processID == processID && $0.isOnScreen
           }) {
            return matchingWindow.id
        }
        return windows.first(where: \.isOnScreen)?.id ?? windows.first?.id
    }

    func hideWindowSelection() {
        windowPresentationGeneration = UUID()
        windowHighlight.hide()
    }

    private static func raiseWindow(_ window: CaptureWindowInfo) -> Bool {
        let application = AXUIElementCreateApplication(window.processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
        let windows = value as? [AXUIElement] else { return false }

        let bestMatch = windows.compactMap { element -> (AXUIElement, CGFloat)? in
            guard let frame = accessibilityFrame(of: element) else { return nil }
            let geometryDifference = abs(frame.minX - window.frame.minX)
                + abs(frame.minY - window.frame.minY)
                + abs(frame.width - window.frame.width)
                + abs(frame.height - window.frame.height)
            let title = accessibilityTitle(of: element)
            let titlePenalty: CGFloat = window.title.isEmpty || title == window.title ? 0 : 10_000
            return (element, geometryDifference + titlePenalty)
        }.min { $0.1 < $1.1 }

        guard let (element, score) = bestMatch, score < 80 else { return false }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        return AXUIElementPerformAction(
            element,
            kAXRaiseAction as CFString
        ) == .success
    }

    private static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func accessibilityTitle(of element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXTitleAttribute as CFString,
            &value
        ) == .success else { return "" }
        return value as? String ?? ""
    }

    private func restoreInteractiveMainWindowLevel() {
        guard let model else { return }
        // The setup/export window must remain reachable while the user still
        // has work to do. It is ordered out before countdown, so floating here
        // never makes it part of the recording workflow.
        mainWindow?.level = model.mode == .region ? .screenSaver : .floating
    }

    func prepareForCountdown(targetProcessID: pid_t?) {
        hideWindowSelection()
        rememberMainScreen()
        mainWindow?.orderOut(nil)
        statusItem?.isVisible = false

        let targetApplication = targetProcessID.flatMap(NSRunningApplication.init(processIdentifier:))
            ?? lastExternalApplication
        targetApplication?.activate(options: [.activateAllWindows])
    }

    func runCountdown(from start: Int) async throws {
        defer {
            countdownSound.stop()
            countdownNumber = nil
            countdownPanels.values.forEach { $0.orderOut(nil) }
            countdownPanels.removeAll()
        }

        for number in stride(from: start, through: 1, by: -1) {
            try Task.checkCancellation()
            countdownNumber = number
            presentCountdown(number: number)
            countdownSound.playTick(number: number)
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func presentCountdown(number: Int) {
        let screens = NSScreen.screens
        let connected = Set(screens.compactMap(ScreenPresentation.displayID))
        for id in countdownPanels.keys.filter({ !connected.contains($0) }) {
            countdownPanels.removeValue(forKey: id)?.orderOut(nil)
        }
        for screen in screens {
            guard let id = ScreenPresentation.displayID(of: screen) else { continue }
            let panel = countdownPanels[id] ?? Self.makeCountdownPanel()
            countdownPanels[id] = panel
            // Use the whole display, not visibleFrame: exact visual center.
            panel.setFrame(ScreenPresentation.centeredFrame(size: CGSize(width: 174, height: 174), in: screen.frame), display: true)
            panel.contentView = NSHostingView(rootView: CountdownView(number: number))
            panel.orderFrontRegardless()
        }
    }

    func showRecordingHUD() {
        guard let model else { return }
        statusItem?.isVisible = true
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
        // 局部录像时选区浮层保持显示；控制条出现即进入录制态，刻度转为信号橙。
        regionOverlay.setRecordingActive(true)
    }

    func hideRecordingHUD() {
        recordingPanel?.orderOut(nil)
        regionOverlay.setRecordingActive(false)
    }

    func showCameraPreview(frames: CameraFrameStore, settings: CameraOverlaySettings) {
        cameraPreview.show(frames: frames, settings: settings, on: presentationScreen)
    }

    func hideCameraPreview() {
        cameraPreview.hide()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }

        // A user-initiated close is an explicit quit request. Keep the window
        // alive until AppDelegate has applied the recording/export safeguards;
        // idle sessions terminate immediately, while protected states can
        // cancel without leaving an invisible menu-bar process behind.
        // Calling terminate synchronously from windowShouldClose re-enters the
        // same AppKit close transaction; the following `false` can then cancel
        // both operations. Leave the window alive for this event and start the
        // guarded quit on the next main-loop turn instead.
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow {
            model?.mainWindowClosed()
        }
    }

    static func makeCountdownPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 174, height: 174),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.title = "录制倒计时"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
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
        let screen = presentationScreen
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
        statusMenu = menu
        item.button?.target = self
        item.button?.action = #selector(showStatusMenu)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func showStatusMenu() {
        guard let menu = statusMenu, let screen = presentationScreen else { return }
        if let window = mainWindow, window.isVisible, let view = window.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - 16, y: view.bounds.maxY - 16), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 8), in: nil)
        }
    }

    @objc private func openSnapRecorder() {
        showMainWindow()
    }

    @objc private func quitSnapRecorder() {
        NSApp.terminate(nil)
    }
}

/// A native AppKit hit target installed above the full-size SwiftUI host view.
/// It occupies only the intentionally empty title-bar strip to avoid stealing
/// gestures from traffic lights or recorder controls.
private final class TitlebarDragSurface: NSView {
    private static let height: CGFloat = 44
    private static let leading: CGFloat = 76
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.alignToHostTop()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, window?.isMovable == true else {
            super.mouseDown(with: event)
            return
        }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStartMouseLocation, let dragStartWindowOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        window.setFrameOrigin(
            NSPoint(
                x: dragStartWindowOrigin.x + mouseLocation.x - dragStartMouseLocation.x,
                y: dragStartWindowOrigin.y + mouseLocation.y - dragStartMouseLocation.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }

    private func alignToHostTop() {
        guard let superview else { return }
        let topY = superview.isFlipped ? 0 : superview.bounds.height - Self.height
        frame = NSRect(
            x: Self.leading,
            y: topY,
            width: max(0, superview.bounds.width - Self.leading),
            height: Self.height
        )
        autoresizingMask = superview.isFlipped
            ? [.width, .maxYMargin]
            : [.width, .minYMargin]
    }
}
