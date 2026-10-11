import AppKit
import Darwin
import Dispatch
import SwiftUI

@main
struct SnapRecorderApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Task.detached {
                do {
                    let report = try await RecordingDiagnostics.run()
                    print(report)
                    Darwin.exit(0)
                } catch {
                    fputs("Snap Recorder self-test failed: \(error.localizedDescription)\n", stderr)
                    Darwin.exit(1)
                }
            }
            dispatchMain()
        }

        let application = NSApplication.shared
        let previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
        let delegate = AppDelegate(previouslyActiveApplication: previouslyActiveApplication)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.mainMenu = makeMainMenu(for: application)
        application.run()
    }

    /// Accessory applications do not receive a reliable Command-Q route unless
    /// they install an application menu explicitly.
    @MainActor
    private static func makeMainMenu(for application: NSApplication) -> NSMenu {
        let mainMenu = NSMenu(title: "Snap Recorder")
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Snap Recorder")
        let quitItem = NSMenuItem(
            title: "退出 Snap Recorder",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = application
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", "undo:", "z"),
            ("剪切", "cut:", "x"),
            ("复制", "copy:", "c"),
            ("粘贴", "paste:", "v"),
            ("全选", "selectAll:", "a")
        ] {
            let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command]
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        return mainMenu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let previouslyActiveApplication: NSRunningApplication?
    private var windowCoordinator: WindowCoordinator?
    private var model: AppModel?

    init(previouslyActiveApplication: NSRunningApplication?) {
        self.previouslyActiveApplication = previouslyActiveApplication
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test-display-panels") {
            Task {
                do {
                    print(try await DisplayPresentationDiagnostics.runNative())
                    Darwin.exit(0)
                } catch {
                    fputs("Display presentation test failed: \(error.localizedDescription)\n", stderr)
                    Darwin.exit(1)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--self-test-window-capture") {
            Task {
                do {
                    print(try await CaptureWindowDiagnostics.run())
                    Darwin.exit(0)
                } catch {
                    fputs("Window capture test failed: \(error.localizedDescription)\n", stderr)
                    Darwin.exit(1)
                }
            }
            return
        }
        let coordinator = WindowCoordinator(
            initialExternalApplication: previouslyActiveApplication
        )
        let model = AppModel(
            captureService: ScreenCaptureService(),
            windowCoordinator: coordinator
        )
        coordinator.attach(model: model)

        self.windowCoordinator = coordinator
        self.model = model
        coordinator.showMainWindow()
        if CommandLine.arguments.contains("--preview-displays") {
            model.mode = .display
            model.captureModeDidChange(.display)
        }
        if RecordingDiagnostics.isExportPreview {
            Task { await model.prepareExportPreview() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.recheckPermission()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Recording deliberately orders the main window out before countdown.
        // AppKit treats that as losing the last window even while auxiliary
        // NSPanels remain visible, so automatic termination would turn the
        // normal recording transition into a quit request. Explicit close and
        // Quit actions are routed through applicationShouldTerminate instead.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let model else { return true }

        switch model.phase {
        case .idle, .preparingExport, .choosingExport, .exporting, .finished, .failed, .recording, .paused:
            windowCoordinator?.showMainWindow()
        case .countdown:
            break
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

        if model.phase == .countdown {
            let alert = NSAlert()
            alert.messageText = "正在准备录制"
            alert.informativeText = "请等录制控制条出现后，再结束或退出 Snap Recorder。"
            alert.addButton(withTitle: "继续等待")
            runAlert(alert)
            return .terminateCancel
        }

        if model.phase.isCapturing {
            let alert = NSAlert()
            alert.messageText = "录屏还在进行"
            alert.informativeText = "先结束录制，再选择保存或放弃。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "结束录制")
            alert.addButton(withTitle: "继续录制")
            if runAlert(alert) == .alertFirstButtonReturn {
                model.stopRecording()
            }
            return .terminateCancel
        }

        if model.isExportWorkspace {
            return model.closeExportSessionIfNeeded() ? .terminateNow : .terminateCancel
        }

        if model.hasRetryableSave {
            let alert = NSAlert()
            alert.messageText = "录屏还没有保存完成"
            alert.informativeText = "临时录屏仍在本机。请先重试保存，避免之后找不到它。"
            alert.addButton(withTitle: "重试保存")
            alert.addButton(withTitle: "继续留在 Snap Recorder")
            if runAlert(alert) == .alertFirstButtonReturn {
                model.retrySavingRecording()
            }
            windowCoordinator?.showMainWindow()
            return .terminateCancel
        }

        if model.phase == .preparingExport || model.phase == .exporting {
            let alert = NSAlert()
            alert.messageText = "正在导出"
            alert.informativeText = "请先完成或取消导出。"
            alert.addButton(withTitle: "知道了")
            runAlert(alert)
            return .terminateCancel
        }

        return .terminateNow
    }

    @discardableResult
    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        windowCoordinator?.runAlert(alert) ?? alert.runModal()
    }
}
