import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Synthetic geometry/images only: running self-test never opens a camera or
/// requires a user's face. Pixel tests render the actual production filter chain.
enum CameraPortraitDiagnostics {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let extent = CGRect(x: 0, y: 0, width: 320, height: 240)

    static func run() throws -> String {
        try validateSettingsAndIdentity()
        try validateSkinMaskAndRendering()
        try validateNoiseReductionAndFeatureEdges()
        try validateDetectionLifecycle()
        return "native portrait original/natural/soft presets, cheek noise reduction, feature/background protection and face-loss recovery passed"
    }

    private static func validateSettingsAndIdentity() throws {
        guard CameraPortraitPreset.allCases.count == 3,
              !CameraPortraitSettings().isEnabled,
              !CameraPortraitSettings(preset: .original).isEnabled,
              CameraPortraitSettings(preset: .natural).isEnabled,
              CameraPortraitSettings(preset: .soft).isEnabled else {
            throw failure("自然修饰三档设置或默认原图状态异常。")
        }
        let source = fixtureImage()
        let mask = CIImage(color: .white).cropped(to: extent)
        let inactive = CameraPortraitProcessor.render(source, settings: .init(), mask: mask)
        let zero = CameraPortraitProcessor.render(source, settings: .init(preset: .original), mask: mask)
        let noFace = CameraPortraitProcessor.render(source, settings: .init(preset: .natural), mask: nil)
        guard pixels(source) == pixels(inactive), pixels(source) == pixels(zero),
              pixels(source) == pixels(noFace), inactive.extent == source.extent else {
            throw failure("原图档或无人脸时没有原样输出。")
        }
    }

    private static func validateSkinMaskAndRendering() throws {
        guard let mask = CameraPortraitProcessor.makeMask(face: fixtureFace(), extent: extent) else {
            throw failure("自然修饰无法生成有效人脸区域。")
        }
        let cheek = CGPoint(x: 119, y: 127)
        guard pixel(mask, at: cheek)[0] > 220,
              pixel(mask, at: CGPoint(x: 200, y: 127))[0] > 220 else {
            throw failure("自然修饰没有覆盖左右脸颊。")
        }
        // Background, eyes, brows, mouth and forehead/hairline must be untouched.
        let protectedPoints = [
            CGPoint(x: 16, y: 16), CGPoint(x: 160, y: 216),
            CGPoint(x: 122, y: 156), CGPoint(x: 198, y: 156),
            CGPoint(x: 120, y: 175), CGPoint(x: 200, y: 175),
            CGPoint(x: 160, y: 99), CGPoint(x: 160, y: 192)
        ]
        guard protectedPoints.allSatisfy({ pixel(mask, at: $0)[0] <= 1 }) else {
            throw failure("自然修饰覆盖到了背景、眼眉、嘴或发际区域。")
        }
        var invalidFace = fixtureFace()
        invalidFace.leftEye = []
        guard CameraPortraitProcessor.makeMask(face: invalidFace, extent: extent) == nil else {
            throw failure("缺少五官信息时仍然生成了自然修饰区域。")
        }

        let source = fixtureImage()
        let settings = CameraPortraitSettings(preset: .soft)
        let corrected = CameraPortraitProcessor.render(source, settings: settings, mask: mask)
        guard corrected.extent == source.extent,
              protectedPoints.allSatisfy({ pixel(source, at: $0) == pixel(corrected, at: $0) }),
              pixel(source, at: cheek) != pixel(corrected, at: cheek) else {
            throw failure("自然修饰没有生效，或改动了画布、背景或五官像素。")
        }
        let low = CameraPortraitProcessor.render(source, settings: .init(preset: .natural), mask: mask)
        let originalCheek = pixel(source, at: cheek)
        func difference(_ image: CIImage) -> Int {
            zip(pixel(image, at: cheek), originalCheek).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        guard difference(low) <= difference(corrected), difference(corrected) < 30 else {
            throw failure("自然修饰强度不连续或档位校正过重。")
        }
        // Even a high-contrast edge outside the face must remain byte-identical.
        let originalPixels = pixels(source)
        let correctedPixels = pixels(corrected)
        for y in 0..<Int(extent.height) {
            for x in [5, 6, 7, 8, 9, 10, 309, 310, 311, 312] {
                let offset = (y * Int(extent.width) + x) * 4
                guard originalPixels[offset..<(offset + 4)] == correctedPixels[offset..<(offset + 4)] else {
                    throw failure("自然修饰模糊了画面背景边缘。")
                }
            }
        }
    }

    private static func validateDetectionLifecycle() throws {
        var calls = 0
        var faceAvailable = true
        let processor = CameraPortraitProcessor(detector: { _ in
            calls += 1
            return faceAvailable ? fixtureFace() : nil
        })
        let buffer = try fixtureBuffer()
        let source = CIImage(cvPixelBuffer: buffer)
        let settings = CameraPortraitSettings(preset: .soft)
        func process(_ time: Double, _ options: CameraPortraitSettings = .init(preset: .soft)) -> CIImage {
            processor.process(buffer, settings: options, presentationTime: CMTime(seconds: time, preferredTimescale: 1_000))
        }
        _ = process(1, .init())
        _ = process(1.01, .init(preset: .original))
        guard calls == 0 else { throw failure("关闭修饰后仍在分析人脸。") }
        let active = process(1.1, settings)
        _ = process(1.15, settings)
        guard calls == 1, pixels(active) != pixels(source) else {
            throw failure("自然修饰没有生效或人脸定位没有节流。")
        }
        faceAvailable = false
        let missing = process(1.3)
        guard calls == 2, pixels(missing) == pixels(source) else {
            throw failure("人脸离开后仍在使用旧的自然修饰区域。")
        }
        faceAvailable = true
        _ = process(1.5)
        processor.reset()
        faceAvailable = false
        guard pixels(process(1.51)) == pixels(source), calls == 4 else {
            throw failure("摄像头重启后仍残留之前的人脸区域。")
        }
        faceAvailable = true
        _ = process(1.7)
        let invalid = processor.process(buffer, settings: settings, presentationTime: .invalid)
        guard pixels(invalid) == pixels(source) else {
            throw failure("无效帧时间没有安全退回原图。")
        }
        faceAvailable = false
        guard pixels(process(0.1)) == pixels(source) else {
            throw failure("帧时间回退后仍沿用旧的人脸区域。")
        }
    }

    private static func validateNoiseReductionAndFeatureEdges() throws {
        guard let mask = CameraPortraitProcessor.makeMask(face: fixtureFace(), extent: extent) else {
            throw failure("无法创建肤质柔化测试区域。")
        }
        let width = Int(extent.width)
        let height = Int(extent.height)
        var random: UInt32 = 47
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            random = random &* 1_664_525 &+ 1_013_904_223
            let noise = Int((random >> 16) % 9) - 4
            for (channel, base) in [150, 110, 85].enumerated() {
                bytes[index + channel] = UInt8(base + noise)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw failure("无法创建肤质噪点测试画面。")
        }
        let eyeEdge = CGRect(x: 111, y: 154, width: 22, height: 4)
        let mouthEdge = CGRect(x: 142, y: 97, width: 36, height: 4)
        let source = CIImage(color: .black).cropped(to: eyeEdge).composited(over:
            CIImage(color: .white).cropped(to: mouthEdge).composited(over: CIImage(cgImage: cgImage)))
            .cropped(to: extent)
        let corrected = CameraPortraitProcessor.render(source, settings: .init(preset: .natural), mask: mask)
        let originalPixels = pixels(source)
        let correctedPixels = pixels(corrected)
        let soft = CameraPortraitProcessor.render(source, settings: .init(preset: .soft), mask: mask)
        let softPixels = pixels(soft)
        func variance(_ samples: [UInt8]) -> Double {
            var values: [Double] = []
            for y in 121..<134 {
                for x in 113..<126 {
                    values.append(Double(samples[(y * width + x) * 4]))
                }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        }
        let before = variance(originalPixels)
        let after = variance(correctedPixels)
        let softVariance = variance(softPixels)
        guard before > 2, after < before * 0.85,
              softVariance < after * 0.90,
              originalPixels != correctedPixels, correctedPixels != softPixels else {
            throw failure("原图/自然/柔和档位缺少实质柔肤区别（\(before) → \(after) → \(softVariance)）。")
        }
        for edge in [eyeEdge, mouthEdge] {
            // Probe on both sides of, and directly on, the artificial feature.
            for y in Int(edge.minY - 1)...Int(edge.maxY) {
                for x in Int(edge.minX - 1)...Int(edge.maxX) {
                    let point = CGPoint(x: x, y: y)
                    guard pixel(source, at: point) == pixel(corrected, at: point),
                          pixel(source, at: point) == pixel(soft, at: point) else {
                        throw failure("自然修饰改变了眼睛或嘴唇的高对比边缘。")
                    }
                }
            }
        }
    }

    private static func fixtureFace() -> CameraPortraitFaceGeometry {
        func oval(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            (0..<12).map { index in
                let angle = CGFloat(index) / 12 * 2 * .pi
                return CGPoint(x: x + cos(angle) * width / 2, y: y + sin(angle) * height / 2)
            }
        }
        return CameraPortraitFaceGeometry(
            boundingBox: CGRect(x: 0.22, y: 0.22, width: 0.56, height: 0.60),
            contour: [CGPoint(x: 0.25, y: 0.72), CGPoint(x: 0.23, y: 0.55),
                      CGPoint(x: 0.29, y: 0.32), CGPoint(x: 0.5, y: 0.24),
                      CGPoint(x: 0.71, y: 0.32), CGPoint(x: 0.77, y: 0.55), CGPoint(x: 0.75, y: 0.72)],
            leftEye: oval(0.38, 0.65, 0.10, 0.035), rightEye: oval(0.62, 0.65, 0.10, 0.035),
            leftEyebrow: oval(0.38, 0.73, 0.12, 0.025), rightEyebrow: oval(0.62, 0.73, 0.12, 0.025),
            lips: oval(0.5, 0.41, 0.20, 0.075)
        )
    }

    private static func fixtureImage() -> CIImage {
        let background = CIImage(color: CIColor(red: 0.50, green: 0.36, blue: 0.28)).cropped(to: extent)
        let edge = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 240))
        return edge.composited(over: background).cropped(to: extent)
    }

    private static func fixtureBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(extent.width), Int(extent.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw failure("无法创建人像修饰自检画面。") }
        context.render(fixtureImage(), to: buffer, bounds: extent, colorSpace: colorSpace)
        return buffer
    }

    private static func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(extent.width) * 4,
                bounds: extent, format: .RGBA8, colorSpace: colorSpace)
        }
        return bytes
    }

    private static func pixel(_ image: CIImage, at point: CGPoint) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1),
                format: .RGBA8, colorSpace: colorSpace)
        }
        return bytes
    }

    private static func failure(_ message: String) -> CaptureError {
        .couldNotFinishWriter(message)
    }
}
