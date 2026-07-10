import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

final class FrameCompositor {
    private let mode: CaptureMode
    private let outputSize: CGSize
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let wallpaper: CIImage?
    private var cachedBackdrop: CIImage?
    private var cachedUnderlay: CIImage?
    private var cachedMask: CIImage?
    private var cachedSourceSize: CGSize?

    init(mode: CaptureMode, outputSize: CGSize, wallpaperURL: URL?) {
        self.mode = mode
        self.outputSize = outputSize
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        self.wallpaper = wallpaperURL.flatMap { CIImage(contentsOf: $0) }
    }

    func render(source pixelBuffer: CVPixelBuffer, into destination: CVPixelBuffer) {
        let source = normalized(CIImage(cvPixelBuffer: pixelBuffer))
        let image: CIImage

        switch mode {
        case .display:
            image = displayComposition(source)
        case .browser:
            image = browserComposition(source)
        }

        context.render(
            image.cropped(to: canvasRect),
            to: destination,
            bounds: canvasRect,
            colorSpace: colorSpace
        )
    }

    private var canvasRect: CGRect {
        CGRect(origin: .zero, size: outputSize)
    }

    private func displayComposition(_ source: CIImage) -> CIImage {
        let background = CIImage(color: .black).cropped(to: canvasRect)
        return aspectFit(source, inside: canvasRect).composited(over: background)
    }

    private func browserComposition(_ source: CIImage) -> CIImage {
        let background = browserBackdrop()
        let safeRect = CaptureSizing.browserContentRect(in: outputSize)
        let fitted = aspectFit(source, inside: safeRect, allowUpscale: false)
        let sourceSize = source.extent.size

        if cachedSourceSize != sourceSize || cachedUnderlay == nil || cachedMask == nil {
            let windowRect = fitted.extent.integral
            let radius = min(24, min(windowRect.width, windowRect.height) * 0.03)
            let mask = roundedMask(in: windowRect, radius: radius)
            let shadow = mask
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.42)
                    ]
                )
                .transformed(by: CGAffineTransform(translationX: 0, y: -10))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
                .cropped(to: canvasRect)

            cachedMask = rasterized(mask)
            cachedUnderlay = rasterized(shadow.composited(over: background))
            cachedSourceSize = sourceSize
        }

        let mask = cachedMask ?? roundedMask(in: fitted.extent.integral, radius: 24)
        let underlay = cachedUnderlay ?? background
        let clearCanvas = CIImage(color: .clear).cropped(to: canvasRect)
        let roundedWindow = fitted.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clearCanvas,
                kCIInputMaskImageKey: mask
            ]
        )

        return roundedWindow.composited(over: underlay)
    }

    private func browserBackdrop() -> CIImage {
        if let cachedBackdrop { return cachedBackdrop }

        var background = aspectFill(wallpaper ?? fallbackGradient(), inside: canvasRect)
        background = background
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
            .cropped(to: canvasRect)

        let tint = CIImage(
            color: CIColor(red: 0.02, green: 0.025, blue: 0.05, alpha: 0.22)
        ).cropped(to: canvasRect)
        background = tint.composited(over: background)
        let rendered = rasterized(background)
        cachedBackdrop = rendered
        return rendered
    }

    private func roundedMask(in rect: CGRect, radius: CGFloat) -> CIImage {
        guard let output = CIFilter(
            name: "CIRoundedRectangleGenerator",
            parameters: [
                "inputExtent": CIVector(cgRect: rect),
                "inputRadius": radius,
                "inputColor": CIColor.white
            ]
        )?.outputImage else {
            return CIImage(color: .white).cropped(to: rect)
        }
        return output.cropped(to: canvasRect)
    }

    private func fallbackGradient() -> CIImage {
        let filter = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: outputSize.width, y: outputSize.height),
                "inputColor0": CIColor(red: 0.12, green: 0.16, blue: 0.31, alpha: 1),
                "inputColor1": CIColor(red: 0.47, green: 0.25, blue: 0.49, alpha: 1)
            ]
        )
        return filter?.outputImage?.cropped(to: canvasRect)
            ?? CIImage(color: CIColor(red: 0.13, green: 0.16, blue: 0.28, alpha: 1)).cropped(to: canvasRect)
    }

    private func rasterized(_ image: CIImage) -> CIImage {
        let cropped = image.cropped(to: canvasRect)
        guard let cgImage = context.createCGImage(
            cropped,
            from: canvasRect,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            return cropped
        }
        return CIImage(cgImage: cgImage).cropped(to: canvasRect)
    }

    private func normalized(_ image: CIImage) -> CIImage {
        image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
    }

    private func aspectFit(
        _ image: CIImage,
        inside rect: CGRect,
        allowUpscale: Bool = true
    ) -> CIImage {
        let source = normalized(image)
        guard source.extent.width > 0, source.extent.height > 0 else { return source }
        let requestedScale = min(
            rect.width / source.extent.width,
            rect.height / source.extent.height
        )
        let scale = allowUpscale ? requestedScale : min(requestedScale, 1)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = rect.midX - scaled.extent.width / 2
        let y = rect.midY - scaled.extent.height / 2
        return scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    private func aspectFill(_ image: CIImage, inside rect: CGRect) -> CIImage {
        let source = normalized(image)
        guard source.extent.width > 0, source.extent.height > 0 else { return source }
        let scale = max(rect.width / source.extent.width, rect.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = rect.midX - scaled.extent.width / 2
        let y = rect.midY - scaled.extent.height / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .cropped(to: rect)
    }
}
