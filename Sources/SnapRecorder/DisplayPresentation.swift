import AppKit
import CoreGraphics

/// Recording selection and UI presentation are intentionally independent.
enum DisplaySelection {
    static func resolve(
        current: CGDirectDisplayID?, available: [CaptureDisplayInfo], preferred: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if let current { return available.contains { $0.id == current } ? current : nil }
        return available.first { $0.id == preferred }?.id
            ?? available.first { $0.isPrimary }?.id ?? available.first?.id
    }
}

enum ScreenPresentation {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func centeredFrame(size: CGSize, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    static func thumbnailSize(source: CGSize, within bounds: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    static func popupFrame(size: CGSize, near anchor: CGRect?, in visible: CGRect) -> CGRect {
        var frame = centeredFrame(size: size, in: anchor ?? visible)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - size.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - size.height))
        return frame
    }
}

enum DisplayPresentationDiagnostics {
    static func run() throws {
        let primary = CaptureDisplayInfo(id: 1, name: "主屏幕", pixelSize: CGSize(width: 3840, height: 2160), isPrimary: true)
        let secondary = CaptureDisplayInfo(id: 2, name: "外接屏幕", pixelSize: CGSize(width: 1920, height: 1080), isPrimary: false)
        guard DisplaySelection.resolve(current: nil, available: [primary, secondary], preferred: 2) == 2,
              DisplaySelection.resolve(current: 1, available: [primary, secondary], preferred: 2) == 1,
              DisplaySelection.resolve(current: 2, available: [primary], preferred: 1) == nil,
              DisplaySelection.resolve(current: nil, available: [], preferred: 1) == nil else {
            throw CaptureError.couldNotFinishWriter("多屏选择发生静默切换或空列表处理异常。")
        }
        // Left, right, above and portrait arrangements, including negative origins.
        for bounds in [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                       CGRect(x: -1440, y: -200, width: 1440, height: 900),
                       CGRect(x: 1920, y: 0, width: 900, height: 1440),
                       CGRect(x: 0, y: 1080, width: 2560, height: 1440)] {
            let countdown = ScreenPresentation.centeredFrame(size: CGSize(width: 174, height: 174), in: bounds)
            let popup = ScreenPresentation.popupFrame(size: CGSize(width: 440, height: 250),
                near: CGRect(x: bounds.maxX - 60, y: bounds.maxY - 40, width: 560, height: 560), in: bounds)
            guard countdown.midX == bounds.midX, countdown.midY == bounds.midY,
                  bounds.contains(countdown), bounds.contains(popup) else {
                throw CaptureError.couldNotFinishWriter("多屏倒计时居中或提示框屏幕边界处理异常。")
            }
        }
        for source in [CGSize(width: 3840, height: 2160), CGSize(width: 2160, height: 3840),
                       CGSize(width: 3440, height: 1440), CGSize(width: 1920, height: 1200)] {
            let size = ScreenPresentation.thumbnailSize(source: source, within: CGSize(width: 280, height: 156))
            guard abs(size.width / size.height - source.width / source.height) < 0.000001,
                  size.width <= 280.000001, size.height <= 156.000001 else {
                throw CaptureError.couldNotFinishWriter("屏幕缩略图被固定比例裁切或拉伸。")
            }
        }
    }

    /// Exercises real native panels without collecting screen, microphone or camera data.
    @MainActor
    static func runNative() async throws -> String {
        let coordinator = WindowCoordinator(initialExternalApplication: nil)
        let model = AppModel(captureService: ScreenCaptureService(), windowCoordinator: coordinator)
        model.permissionGranted = false
        model.mode = .region // Exercise the highest main-window level without capture.
        coordinator.attach(model: model)
        coordinator.showMainWindow()
        guard let main = NSApp.windows.first(where: { $0.title == "Snap Recorder" }) else {
            throw CaptureError.couldNotFinishWriter("屏幕定位测试没有主面板。")
        }
        defer { main.orderOut(nil) }
        let screens = NSScreen.screens
        for screen in screens {
            main.setFrame(ScreenPresentation.centeredFrame(size: main.frame.size, in: screen.visibleFrame), display: true)
            try await Task.sleep(for: .milliseconds(60))
            let alert = NSAlert()
            alert.messageText = "屏幕定位检查"
            alert.informativeText = "仅验证提示框位置 不会录屏"
            alert.addButton(withTitle: "继续")
            var isCorrect = false
            var placementDetail = ""
            let targetID = ScreenPresentation.displayID(of: screen)
            let visibleFrame = screen.visibleFrame
            let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
                isCorrect = alert.window.screen.flatMap(ScreenPresentation.displayID) == targetID
                    && visibleFrame.contains(alert.window.frame)
                    && alert.window.level.rawValue > main.level.rawValue
                placementDetail = "target \(targetID ?? 0), actual \(alert.window.screen.flatMap(ScreenPresentation.displayID) ?? 0), frame \(alert.window.frame), visible \(visibleFrame), levels \(alert.window.level.rawValue)/\(main.level.rawValue)"
                alert.buttons.first?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            let response = coordinator.runAlert(alert)
            timer.invalidate()
            guard isCorrect else {
                throw CaptureError.couldNotFinishWriter("提示框未跟随主面板所在屏幕或层级不正确：response \(response.rawValue), \(placementDetail)")
            }
        }
        main.orderOut(nil)
        let task = Task { try await coordinator.runCountdown(from: 3) }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(250))
        let panels = NSApp.windows.filter { $0.title == "录制倒计时" && $0.isVisible }
        guard !screens.isEmpty, panels.count == screens.count else {
            task.cancel()
            _ = try? await task.value
            throw CaptureError.couldNotFinishWriter("每块本地屏幕没有恰好一个倒计时面板。")
        }
        for screen in screens {
            guard let panel = panels.first(where: {
                abs($0.frame.midX - screen.frame.midX) < 0.5 && abs($0.frame.midY - screen.frame.midY) < 0.5
            }), !panel.isMovable, !panel.isMovableByWindowBackground,
                panel.ignoresMouseEvents, panel.sharingType == .none else {
                task.cancel()
                _ = try? await task.value
                throw CaptureError.couldNotFinishWriter("倒计时面板未居中或未锁定拖动与共享。")
            }
        }
        task.cancel()
        _ = try? await task.value
        guard panels.allSatisfy({ !$0.isVisible }) else {
            throw CaptureError.couldNotFinishWriter("取消倒计时后仍有残留面板。")
        }
        try await coordinator.runCountdown(from: 1)
        guard !NSApp.windows.contains(where: { $0.title == "录制倒计时" && $0.isVisible }) else {
            throw CaptureError.couldNotFinishWriter("倒计时完成后仍有残留面板。")
        }
        return "Native display presentation passed on \(screens.count) connected display(s): alerts follow main panel above its level; countdown centered, immovable, click-through and non-shareable; cancellation and completion cleaned every panel."
    }
}
