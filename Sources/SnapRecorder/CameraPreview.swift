import AppKit
import CoreImage
import CoreMedia

/// A camera-only monitor sharing the encoder's already-processed frames.
/// This non-shareable, click-through panel can never become a second overlay.
@MainActor
final class CameraPreviewController {
    private var panel: NSPanel?
    private var preview: CameraPreviewView?

    func show(frames: CameraFrameStore, settings: CameraOverlaySettings) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID()
        }) ?? NSScreen.main else { return }
        let panel: NSPanel
        let preview: CameraPreviewView
        if let existing = self.panel, let view = self.preview {
            panel = existing
            preview = view
        } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "摄像头预览"
            panel.level = .screenSaver
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.sharingType = .none
            preview = CameraPreviewView(frame: .zero)
            panel.contentView = preview
            self.panel = panel
            self.preview = preview
        }
        let visible = screen.visibleFrame
        let rect = settings.rect(in: visible.size).offsetBy(dx: visible.minX, dy: visible.minY)
        let padding: CGFloat = 14
        let frame = rect.insetBy(dx: -padding, dy: -padding)
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: panel.isVisible)
        }
        preview.configure(frames: frames, settings: settings, padding: padding)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        preview?.detach()
    }
}

/// Image conversion stays off the UI thread, with at most one frame in flight.
/// Downscaling here affects only the monitor, never the recorded camera image.
private final class CameraPreviewRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.shuyan-5200.SnapRecorder.camera-preview", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func render(_ frame: CameraFrame, completion: @escaping @Sendable (CGImage?) -> Void) {
        queue.async { [self] in
            autoreleasepool {
                let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
                let scale = min(1, 800 / max(source.extent.width, source.extent.height))
                let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                completion(context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace))
            }
        }
    }
}

@MainActor
private final class CameraPreviewView: NSView {
    private let cameraLayer = CALayer()
    private let border = CALayer()
    private let renderer = CameraPreviewRenderer()
    private var settings = CameraOverlaySettings()
    private var padding: CGFloat = 14
    private var frames: CameraFrameStore?
    private var timer: Timer?
    private var lastFrameTime = CMTime.invalid
    private var rendering = false
    private var generation = UUID()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        cameraLayer.contentsGravity = .resizeAspectFill
        cameraLayer.masksToBounds = true
        layer?.addSublayer(cameraLayer)
        border.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        border.borderWidth = 1
        border.shadowColor = NSColor.black.cgColor
        border.shadowOpacity = 0.3
        border.shadowRadius = 9
        border.shadowOffset = CGSize(width: 0, height: -3)
        layer?.insertSublayer(border, below: cameraLayer)
    }

    required init?(coder: NSCoder) { nil }

    func configure(frames: CameraFrameStore, settings: CameraOverlaySettings, padding: CGFloat) {
        self.frames = frames
        self.settings = settings
        self.padding = padding
        needsLayout = true
        layoutSubtreeIfNeeded()
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshFrame() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refreshFrame()
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        frames = nil
        generation = UUID()
        lastFrameTime = .invalid
        rendering = false
        cameraLayer.contents = nil
    }

    private func refreshFrame() {
        guard !rendering, let frame = frames?.latestFrame(),
              CMTimeCompare(frame.presentationTime, lastFrameTime) != 0 else { return }
        rendering = true
        lastFrameTime = frame.presentationTime
        let generation = generation
        renderer.render(frame) { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.rendering = false
                guard let image else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.cameraLayer.contents = image
                CATransaction.commit()
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = bounds.insetBy(dx: padding, dy: padding)
        let radius = settings.cornerRadius(for: rect)
        cameraLayer.setAffineTransform(.identity)
        cameraLayer.frame = rect
        cameraLayer.setAffineTransform(CGAffineTransform(scaleX: settings.mirrored ? -1 : 1, y: 1))
        cameraLayer.cornerRadius = radius
        cameraLayer.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        cameraLayer.borderWidth = 1
        border.frame = rect
        border.cornerRadius = radius
        border.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }
}
