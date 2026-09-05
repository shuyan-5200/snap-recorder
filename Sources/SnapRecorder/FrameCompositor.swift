import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

final class FrameCompositor {
    private let mode: CaptureMode
    private let outputSize: CGSize
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let captureCornerStyle: FocusMaskCornerStyle
    private let appliesSoftCornerVignette: Bool
    private let focusMask: CaptureFocusMask?
    private let cameraOverlayRenderer: CameraOverlayRenderer?

    init(
        mode: CaptureMode,
        outputSize: CGSize,
        captureCornerStyle: FocusMaskCornerStyle = .square,
        appliesSoftCornerVignette: Bool = false,
        focusMask: CaptureFocusMask? = nil,
        cameraOverlay: CameraOverlaySettings? = nil
    ) {
        self.mode = mode
        self.outputSize = outputSize
        self.captureCornerStyle = captureCornerStyle
        self.appliesSoftCornerVignette = appliesSoftCornerVignette
        self.focusMask = focusMask
        self.cameraOverlayRenderer = cameraOverlay.map {
            CameraOverlayRenderer(settings: $0, outputSize: outputSize)
        }
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    }

    func render(
        source pixelBuffer: CVPixelBuffer,
        into destination: CVPixelBuffer,
        mouseEffect: MouseEffectSnapshot? = nil,
        cameraFrame: CameraFrame? = nil
    ) {
        let source = normalized(CIImage(cvPixelBuffer: pixelBuffer))
        var image: CIImage

        switch mode {
        case .display, .region:
            image = displayComposition(source)
        case .browser:
            image = browserComposition(source)
        }

        if mode == .region, let focusMask {
            image = applyingFocusMask(focusMask, to: image)
        }
        if mode == .region, captureCornerStyle == .rounded {
            image = applyingCaptureCorners(
                to: image,
                feathered: appliesSoftCornerVignette
            )
        }
        if let mouseEffect {
            image = applyingMouseEffect(mouseEffect, to: image)
        }
        if let cameraFrame, let cameraOverlayRenderer {
            image = cameraOverlayRenderer.composite(cameraFrame.pixelBuffer, over: image)
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
        let background = CIImage(color: .black).cropped(to: canvasRect)
        return aspectFit(source, inside: canvasRect).composited(over: background)
    }

    private func applyingFocusMask(
        _ focusMask: CaptureFocusMask,
        to image: CIImage
    ) -> CIImage {
        let normalized = focusMask.normalizedRect.standardized
        let focusRect = CGRect(
            x: min(max(normalized.minX, 0), 1) * canvasRect.width,
            y: min(max(normalized.minY, 0), 1) * canvasRect.height,
            width: min(max(normalized.width, 0), 1) * canvasRect.width,
            height: min(max(normalized.height, 0), 1) * canvasRect.height
        ).intersection(canvasRect)
        guard focusRect.width >= 2, focusRect.height >= 2 else { return image }

        let monochromeAndDimmed = image
            .applyingFilter(
                "CIColorControls",
                parameters: [kCIInputSaturationKey: 0]
            )
            .applyingFilter(
                "CIExposureAdjust",
                parameters: [kCIInputEVKey: -1]
            )
        let radius: CGFloat
        switch focusMask.cornerStyle {
        case .square:
            radius = 0
        case .rounded:
            radius = min(30, max(10, min(focusRect.width, focusRect.height) * 0.035))
        }
        guard let mask = roundedMask(in: focusRect, radius: radius) else {
            return image
        }
        return image.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: monochromeAndDimmed,
                kCIInputMaskImageKey: mask
            ]
        )
    }

    private func applyingCaptureCorners(
        to image: CIImage,
        feathered: Bool
    ) -> CIImage {
        let minimumDimension = min(canvasRect.width, canvasRect.height)
        let radius = min(52, max(18, minimumDimension * 0.04))
        let mask: CIImage
        if feathered {
            let feather = min(14, max(5, minimumDimension * 0.006))
            let extendedRect = canvasRect.insetBy(dx: -feather, dy: -feather)
            guard let baseMask = roundedMask(
                in: extendedRect,
                radius: radius + feather
            ) else { return image }
            mask = baseMask
                .applyingFilter(
                    "CIGaussianBlur",
                    parameters: [kCIInputRadiusKey: feather]
                )
                .cropped(to: canvasRect)
        } else {
            guard let baseMask = roundedMask(in: canvasRect, radius: radius) else {
                return image
            }
            mask = baseMask.cropped(to: canvasRect)
        }
        let black = CIImage(color: .black).cropped(to: canvasRect)
        return image.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: black,
                kCIInputMaskImageKey: mask
            ]
        )
    }

    private func applyingMouseEffect(
        _ snapshot: MouseEffectSnapshot,
        to image: CIImage
    ) -> CIImage {
        var result = image
        let scale = min(2.25, max(0.65, min(canvasRect.width, canvasRect.height) / 1_080))

        if let click = snapshot.clickEffect {
            let progress = min(max(click.progress, 0), 1)
            let center = canvasPoint(for: click.normalizedPosition)
            let radius = (14 + 42 * progress) * scale
            let lineWidth = (3.2 - 1.4 * progress) * scale
            let opacity = pow(1 - progress, 1.35) * 0.78

            if let ringMask = ringMask(
                center: center,
                radius: radius,
                lineWidth: lineWidth
            ) {
                let ring = coloredLayer(
                    color: CIColor(red: 0.98, green: 0.30, blue: 0.58, alpha: opacity),
                    mask: ringMask
                )
                result = ring.composited(over: result)
            }
        }

        if let normalizedCursorPosition = snapshot.normalizedCursorPosition {
            let center = canvasPoint(for: normalizedCursorPosition)
            if let haloMask = radialMask(
                center: center,
                innerRadius: 3 * scale,
                outerRadius: 22 * scale
            ) {
                let halo = coloredLayer(
                    color: CIColor(red: 0.67, green: 0.28, blue: 0.98, alpha: 0.5),
                    mask: haloMask
                )
                result = halo.composited(over: result)
            }
            if let coreMask = radialMask(
                center: center,
                innerRadius: 5.2 * scale,
                outerRadius: 7.2 * scale
            ) {
                let core = coloredLayer(
                    color: CIColor(red: 1, green: 0.97, blue: 1, alpha: 0.98),
                    mask: coreMask
                )
                result = core.composited(over: result)
            }
        }

        return result
    }

    private func canvasPoint(for normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(normalizedPoint.x, 0), 1) * canvasRect.width,
            y: (1 - min(max(normalizedPoint.y, 0), 1)) * canvasRect.height
        )
    }

    private func ringMask(
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat
    ) -> CIImage? {
        guard let outer = radialMask(
            center: center,
            innerRadius: max(0, radius - lineWidth * 0.5),
            outerRadius: radius + lineWidth * 0.5
        ), let inner = radialMask(
            center: center,
            innerRadius: max(0, radius - lineWidth * 1.5),
            outerRadius: max(0.5, radius - lineWidth * 0.5)
        ) else { return nil }

        return outer
            .applyingFilter(
                "CISourceOutCompositing",
                parameters: [kCIInputBackgroundImageKey: inner]
            )
            .cropped(to: canvasRect)
    }

    private func radialMask(
        center: CGPoint,
        innerRadius: CGFloat,
        outerRadius: CGFloat
    ) -> CIImage? {
        guard outerRadius > innerRadius,
              let filter = CIFilter(name: "CIRadialGradient") else { return nil }
        filter.setValue(CIVector(cgPoint: center), forKey: kCIInputCenterKey)
        filter.setValue(innerRadius, forKey: "inputRadius0")
        filter.setValue(outerRadius, forKey: "inputRadius1")
        filter.setValue(CIColor.white, forKey: "inputColor0")
        filter.setValue(CIColor.clear, forKey: "inputColor1")
        return filter.outputImage?.cropped(to: canvasRect)
    }

    private func coloredLayer(color: CIColor, mask: CIImage) -> CIImage {
        let foreground = CIImage(color: color).cropped(to: canvasRect)
        let transparent = CIImage(color: .clear).cropped(to: canvasRect)
        return foreground.applyingFilter(
            "CIBlendWithAlphaMask",
            parameters: [
                kCIInputBackgroundImageKey: transparent,
                kCIInputMaskImageKey: mask
            ]
        )
    }

    private func roundedMask(in rect: CGRect, radius: CGFloat) -> CIImage? {
        if radius <= 0 {
            return CIImage(color: .white).cropped(to: rect)
        }
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else {
            return nil
        }
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: kCIInputColorKey)
        return filter.outputImage
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
}
