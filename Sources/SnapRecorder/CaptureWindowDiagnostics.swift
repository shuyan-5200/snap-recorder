import AppKit
import AVFoundation
import ScreenCaptureKit

/// Explicit, local-only integration test. Captures just the interior of a generated
/// green window; no microphone, camera, desktop background or user content is saved.
@MainActor
enum CaptureWindowDiagnostics {
    static func run() async throws -> String {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionRequired }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapRecorder-window-policy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = WindowCoordinator.makeMainWindow()
        panel.setContentSize(NSSize(width: 560, height: 430))
        panel.center()
        panel.level = .floating
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 430))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1).cgColor
        panel.contentView = canvas
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        let service = ScreenCaptureService()
        let mainPanel = try await service.capturableMainWindow(windowID: CGWindowID(panel.windowNumber))
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.frame.contains(mainPanel.frame) }) else {
            throw CaptureError.couldNotStartWriter("测试窗口必须完整位于一个显示器内。")
        }
        // The filter retains the window identity across the normal countdown hide/show.
        panel.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))
        panel.orderFrontRegardless()
        let rect = mainPanel.frame.insetBy(dx: 48, dy: 65)
            .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let request = CaptureRequest(mode: .region, browserWindowID: nil,
            region: CaptureRegion(displayID: display.displayID, sourceRect: rect), focusMask: nil,
            captureCornerStyle: .square, appliesSoftCornerVignette: false, capturesMouseEffects: false,
            capturesSystemAudio: false, capturesMicrophone: false,
            outputURL: directory.appendingPathComponent("window-policy.mp4"))
        try await service.start(request, mainPanel: mainPanel)
        let helper = NSPanel(contentRect: NSRect(x: panel.frame.midX - 110, y: panel.frame.midY - 90, width: 220, height: 180),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        helper.isReleasedWhenClosed = false
        helper.level = .screenSaver
        helper.backgroundColor = .red
        helper.isOpaque = true
        // Even a new shareable helper created AFTER stream start must be excluded.
        // Production auxiliary panels additionally use .none.
        helper.sharingType = .readOnly
        helper.orderFrontRegardless()
        defer { helper.orderOut(nil) }
        do {
            for index in 0..<24 {
                canvas.layer?.backgroundColor = NSColor(srgbRed: 0.1,
                    green: index.isMultiple(of: 2) ? 0.8 : 0.65, blue: 0.2, alpha: 1).cgColor
                try await Task.sleep(for: .milliseconds(70))
            }
            _ = try await service.stop()
        } catch {
            _ = try? await service.stop()
            try? service.discardPendingRecording()
            throw error
        }
        helper.orderOut(nil)
        defer { try? service.discardPendingRecording() }
        let result = try await service.exportPendingRecording(qualityPreset: .maximum,
            selection: RecordingExportSelection(tracks: [.video], arrangement: .merged))
        guard let url = result.primaryURL else { throw CaptureError.noVideoFrames }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 1 else { throw CaptureError.couldNotFinishWriter("窗口测试录制时长不足。") }
        let generator = AVAssetImageGenerator(asset: asset)
        for fraction in [0.25, 0.5, 0.8] {
            let image = try await generator.image(at: CMTime(seconds: duration * fraction, preferredTimescale: 600)).image
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            pixels.withUnsafeMutableBytes { memory in
                let context = CGContext(data: memory.baseAddress, width: 64, height: 64, bitsPerComponent: 8,
                    bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            var green = 0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
                if g > r + 60 && g > b + 40 { green += 1 }
            }
            guard green > 4_000 else {
                throw CaptureError.couldNotFinishWriter("主面板未录入或浮窗混入：绿色像素 \(green)/4096。")
            }
        }
        return "Window capture passed: visible main panel retained after hide/show; later-created helper excluded; 3 decoded frame checks passed."
    }
}
