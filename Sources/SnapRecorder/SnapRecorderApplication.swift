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
        application.run()
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
        if RecordingDiagnostics.isExportPreview {
            Task { await model.prepareExportPreview() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.recheckPermission()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
            alert.runModal()
            return .terminateCancel
        }

        if model.phase.isCapturing {
            let alert = NSAlert()
            alert.messageText = "录屏还在进行"
            alert.informativeText = "先结束录制，再选择保存或放弃。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "结束录制")
            alert.addButton(withTitle: "继续录制")
            if alert.runModal() == .alertFirstButtonReturn {
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
            if alert.runModal() == .alertFirstButtonReturn {
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
            alert.runModal()
            return .terminateCancel
        }

        return .terminateNow
    }
}
