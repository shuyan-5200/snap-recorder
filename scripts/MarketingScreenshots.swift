import AppKit
import SwiftUI
import Darwin

/// Offscreen rendering of the actual app view, with public demonstration data.
/// This does not capture a screen, a camera, microphone, real windows or cursor.
@main
enum MarketingScreenshots {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await render(scene: CommandLine.arguments[1], destination: CommandLine.arguments[2])
                Darwin.exit(0)
            } catch {
                fputs("Screenshot rendering failed: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
        application.run()
    }

    @MainActor
    static func render(scene: String, destination: String) async throws {
        let coordinator = WindowCoordinator(initialExternalApplication: nil)
        let model = AppModel(captureService: ScreenCaptureService(), windowCoordinator: coordinator)
        model.configureMarketingScene(scene)
        let size = CGSize(width: ["export", "portrait"].contains(scene) ? 938 : 560, height: 560)
        // Render the view at the final pixel dimensions, rather than enlarging
        // a low-resolution cached layer when writing the PNG.
        let scale: CGFloat = 3
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let view = NSHostingView(rootView: RecorderView(model: model)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: pixelSize.width, height: pixelSize.height, alignment: .topLeading))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: pixelSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: pixelSize)
        view.layoutSubtreeIfNeeded()
        // onAppear sees permission=false, so it cannot enumerate or capture
        // any real user windows. Changing only permission then reveals fixtures.
        try await Task.sleep(for: .milliseconds(250))
        model.revealMarketingScene(scene)
        try await Task.sleep(for: .milliseconds(350))
        view.layoutSubtreeIfNeeded()
        try snapshot(view, bounds: view.bounds, destination: destination)
        if scene == "export" || scene == "portrait" {
            let bounds = CGRect(x: (scene == "export" ? 572 : 12) * scale, y: 12 * scale,
                                width: 354 * scale, height: 536 * scale)
            let detail = URL(fileURLWithPath: destination).deletingPathExtension().path + "-detail.png"
            try snapshot(view, bounds: bounds, destination: detail)
        }
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    static func snapshot(_ view: NSView, bounds: CGRect, destination: String) throws {
        let scale = 1
        let size = bounds.size
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: URL(fileURLWithPath: destination))
        print("\(URL(fileURLWithPath: destination).lastPathComponent): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh), \(data.count) bytes")
    }

    @MainActor
    static func demoDisplay() -> CGImage {
        // A simple, original presentation slide for the display thumbnail.
        let image = NSImage(size: CGSize(width: 960, height: 540))
        image.lockFocus()
        NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.87, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 960, height: 540)).fill()
        NSColor(calibratedRed: 0.17, green: 0.25, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 590, y: 50, width: 300, height: 440), xRadius: 150, yRadius: 150).fill()
        NSColor(calibratedRed: 0.88, green: 0.43, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(ovalIn: CGRect(x: 650, y: 240, width: 180, height: 180)).fill()
        ("GOOD IDEAS, CLEARLY SHARED." as NSString).draw(at: CGPoint(x: 58, y: 450),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.darkGray])
        ("让好想法\n被看见。" as NSString).draw(in: CGRect(x: 56, y: 178, width: 530, height: 215),
            withAttributes: [.font: NSFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: NSColor.black])
        ("一段清楚的演示，胜过来回解释。" as NSString).draw(at: CGPoint(x: 60, y: 135),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.darkGray])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}
