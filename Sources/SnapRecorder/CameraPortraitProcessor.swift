import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Vision

enum CameraPortraitPreset: String, CaseIterable, Identifiable {
    case original, natural, soft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "原图"
        case .natural: "自然"
        case .soft: "柔和"
        }
    }
    var subtitle: String {
        switch self {
        case .original: "保留原始画面，不做修饰"
        case .natural: "轻柔肤质，保留皮肤纹理"
        case .soft: "加强柔肤，五官与脸型保持不变"
        }
    }
}

struct CameraPortraitSettings: Equatable {
    var preset: CameraPortraitPreset = .original
    var isEnabled: Bool { preset != .original }
}

/// Geometry is in normalized, unmirrored image coordinates, with a lower-left
/// origin. Keeping it separate from Vision allows camera-free regression tests.
struct CameraPortraitFaceGeometry {
    var boundingBox: CGRect
    var contour: [CGPoint]
    var leftEye: [CGPoint]
    var rightEye: [CGPoint]
    var leftEyebrow: [CGPoint]
    var rightEyebrow: [CGPoint]
    var lips: [CGPoint]
}

/// All methods, including reset(), belong on the camera's serial capture queue.
/// The caller renders the result once into an owned buffer shared by preview and
/// recording. This object never opens a camera or retains captured face images.
final class CameraPortraitProcessor {
    typealias FaceDetector = (CIImage) -> CameraPortraitFaceGeometry?

    private let detectFace: FaceDetector
    private var lastDetectionTime: CMTime = .invalid
    private var maskTime: CMTime = .invalid
    private var cachedExtent: CGRect = .zero
    private var cachedMask: CIImage?
    private static let detectionInterval = 0.125
    private static let maximumMaskAge = 0.2

    init(detector: FaceDetector? = nil) {
        detectFace = detector ?? Self.detect
    }

    func reset() {
        lastDetectionTime = .invalid
        maskTime = .invalid
        cachedExtent = .zero
        cachedMask = nil
    }

    func process(
        _ pixelBuffer: CVPixelBuffer,
        settings: CameraPortraitSettings,
        presentationTime: CMTime
    ) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard settings.isEnabled,
              presentationTime.isNumeric,
              image.extent.width > 0, image.extent.height > 0 else {
            reset()
            return image
        }

        let elapsed = CMTimeSubtract(presentationTime, lastDetectionTime).seconds
        if cachedExtent != image.extent || !elapsed.isFinite || elapsed < 0 {
            reset()
            cachedExtent = image.extent
        }
        let sinceDetection = CMTimeSubtract(presentationTime, lastDetectionTime).seconds
        if !sinceDetection.isFinite || sinceDetection >= Self.detectionInterval {
            lastDetectionTime = presentationTime
            // No face, incomplete landmarks, or a Vision error immediately clears
            // the old mask. Never fall back to smoothing the entire camera frame.
            if let face = detectFace(image), let mask = Self.makeMask(face: face, extent: image.extent) {
                cachedMask = mask
                maskTime = presentationTime
            } else {
                cachedMask = nil
                maskTime = .invalid
            }
        }

        let age = CMTimeSubtract(presentationTime, maskTime).seconds
        guard age.isFinite, age >= 0, age <= Self.maximumMaskAge,
              let cachedMask else { return image }
        return Self.render(image, settings: settings, mask: cachedMask)
    }

    /// Modest edge-preserving noise reduction and a tiny tonal lift, mixed back
    /// into the original. No face warp, whitening, makeup, or generic face blur.
    static func render(_ image: CIImage, settings: CameraPortraitSettings, mask: CIImage?) -> CIImage {
        guard settings.isEnabled, let mask else { return image }
        let isSoft = settings.preset == .soft
        let softened = image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": isSoft ? 0.09 : 0.055,
            "inputSharpness": isSoft ? 0.10 : 0.25
        ]).cropped(to: image.extent).applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: isSoft ? 1.02 : 1.01,
            kCIInputBrightnessKey: isSoft ? 0.020 : 0.012,
            kCIInputContrastKey: 1.0
        ])
        // Discrete, calibrated presets instead of an imperceptible 0–100 scale.
        let strength = isSoft ? 0.85 : 0.60
        let weightedMask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0)
        ])
        return softened.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: weightedMask
        ]).cropped(to: image.extent)
    }

    /// Treats the inner cheeks: guessing an entire skin
    /// silhouette from a face rectangle would also soften hair, beards, eyes and
    /// background. Eye/brow/lip landmarks receive an additional exclusion margin.
    static func makeMask(face: CameraPortraitFaceGeometry, extent: CGRect) -> CIImage? {
        let allPoints = face.contour + face.leftEye + face.rightEye
            + face.leftEyebrow + face.rightEyebrow + face.lips
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite,
              face.boundingBox.width > 0.06, face.boundingBox.height > 0.06,
              face.contour.count >= 5, face.leftEye.count >= 3,
              face.rightEye.count >= 3, face.leftEyebrow.count >= 2,
              face.rightEyebrow.count >= 2, face.lips.count >= 3,
              allPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            return nil
        }
        let scale = min(1, 512 / max(extent.width, extent.height))
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let drawing = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(x: value.x * bounds.width, y: value.y * bounds.height)
        }
        func center(_ points: [CGPoint]) -> CGPoint {
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return point(CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count)))
        }
        let eyes = [center(face.leftEye), center(face.rightEye)].sorted { $0.x < $1.x }
        let eyeSpan = hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y)
        guard eyeSpan > 4 else { return nil }
        let horizontal = CGPoint(x: (eyes[1].x - eyes[0].x) / eyeSpan, y: (eyes[1].y - eyes[0].y) / eyeSpan)
        let downward = CGPoint(x: horizontal.y, y: -horizontal.x)
        let eyeCenter = CGPoint(x: (eyes[0].x + eyes[1].x) * 0.5, y: (eyes[0].y + eyes[1].y) * 0.5)
        let mouth = center(face.lips)
        let cheekHeight = (mouth.x - eyeCenter.x) * downward.x + (mouth.y - eyeCenter.y) * downward.y
        // Side profiles and unreliable landmark configurations get no correction.
        guard cheekHeight > eyeSpan * 0.25, cheekHeight < eyeSpan * 1.5 else { return nil }

        drawing.setFillColor(gray: 0, alpha: 1)
        drawing.fill(bounds)
        drawing.saveGState()
        let contour = CGMutablePath()
        contour.addLines(between: face.contour.map(point))
        contour.closeSubpath()
        drawing.addPath(contour)
        drawing.clip()
        drawing.setFillColor(gray: 1, alpha: 1)
        let angle = atan2(horizontal.y, horizontal.x)
        for (index, eye) in eyes.enumerated() {
            let outward: CGFloat = index == 0 ? -1 : 1
            let cheekCenter = CGPoint(
                x: eye.x + downward.x * cheekHeight * 0.50 + horizontal.x * eyeSpan * 0.035 * outward,
                y: eye.y + downward.y * cheekHeight * 0.50 + horizontal.y * eyeSpan * 0.035 * outward
            )
            drawing.saveGState()
            drawing.translateBy(x: cheekCenter.x, y: cheekCenter.y)
            drawing.rotate(by: angle)
            drawing.fillEllipse(in: CGRect(
                x: -eyeSpan * 0.32, y: -cheekHeight * 0.44,
                width: eyeSpan * 0.64, height: cheekHeight * 0.88
            ))
            drawing.restoreGState()
        }
        drawing.restoreGState()

        drawing.setFillColor(gray: 0, alpha: 1)
        drawing.setStrokeColor(gray: 0, alpha: 1)
        drawing.setLineJoin(.round)
        drawing.setLineCap(.round)
        drawing.setLineWidth(max(2, eyeSpan * 0.16))
        for feature in [face.leftEye, face.rightEye, face.leftEyebrow, face.rightEyebrow, face.lips] {
            let path = CGMutablePath()
            path.addLines(between: feature.map(point))
            path.closeSubpath()
            drawing.addPath(path)
            drawing.drawPath(using: .fillStroke)
        }
        guard let bitmap = drawing.makeImage() else { return nil }
        return CIImage(cgImage: bitmap)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.8, eyeSpan * 0.035)])
            .cropped(to: bounds)
            .transformed(by: CGAffineTransform(scaleX: extent.width / bounds.width, y: extent.height / bounds.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    private static func detect(_ image: CIImage) -> CameraPortraitFaceGeometry? {
        let scale = min(1, 384 / max(image.extent.width, image.extent.height))
        let smallImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectFaceLandmarksRequest()
        do {
            try VNImageRequestHandler(ciImage: smallImage, orientation: .up, options: [:]).perform([request])
        } catch {
            return nil
        }
        // The recorder has one presenter. Choosing the largest face avoids
        // spending work on incidental people in the background.
        guard let observation = request.results?.filter({ $0.confidence >= 0.6 }).max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), let landmarks = observation.landmarks,
              abs(observation.yaw?.doubleValue ?? 0) < 0.65 else { return nil }
        let box = observation.boundingBox
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.normalizedPoints.map {
                CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height)
            } ?? []
        }
        return CameraPortraitFaceGeometry(
            boundingBox: box,
            contour: points(landmarks.faceContour),
            leftEye: points(landmarks.leftEye), rightEye: points(landmarks.rightEye),
            leftEyebrow: points(landmarks.leftEyebrow), rightEyebrow: points(landmarks.rightEyebrow),
            lips: points(landmarks.outerLips)
        )
    }
}
