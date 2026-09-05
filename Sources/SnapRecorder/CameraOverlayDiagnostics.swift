import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Synthetic frames exercise camera export without opening a physical camera.
enum CameraOverlayDiagnostics {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func run() async throws -> String {
        try validateFrameStore()
        try validateLayoutsAndMasks()
        try validateMirrorAndLayerOrder()
        try await validateStaticScreenAndPause()
        return "camera frame selection, overlay, mirror, static-screen motion and pause passed"
    }

    private static func validateFrameStore() throws {
        let store = CameraFrameStore()
        let image = try buffer(size: CGSize(width: 16, height: 16), color: .blue)
        func time(_ milliseconds: Int64) -> CMTime {
            CMTime(value: milliseconds, timescale: 1_000)
        }
        func append(_ milliseconds: Int64) {
            store.append(CameraFrame(pixelBuffer: image, presentationTime: time(milliseconds)))
        }
        func hasTime(_ frame: CameraFrame?, _ milliseconds: Int64) -> Bool {
            guard let frame else { return false }
            return CMTimeCompare(frame.presentationTime, time(milliseconds)) == 0
        }

        append(1_000)
        append(1_100)
        append(1_200)
        guard hasTime(store.frame(at: time(1_160)), 1_100),
              hasTime(store.frame(at: time(1_200)), 1_200),
              store.frame(at: time(900)) == nil,
              hasTime(store.frame(at: time(1_190)), 1_100) else {
            throw failure("摄像头帧没有按采集时间匹配，或选择了未来帧。")
        }

        // An out-of-order delivery must not replace the most recent image.
        append(1_050)
        store.append(CameraFrame(pixelBuffer: image, presentationTime: .invalid))
        guard hasTime(store.latestFrame(), 1_200),
              hasTime(store.frame(at: time(1_650)), 1_200),
              store.frame(at: time(1_701)) == nil,
              store.frame(at: .invalid) == nil else {
            throw failure("摄像头帧乱序、无效时间戳或过期判断异常。")
        }

        store.clear()
        guard store.latestFrame() == nil, store.frame(at: time(1_200)) == nil else {
            throw failure("关闭摄像头后仍保留旧画面。")
        }

        // Retain exactly the three newest source buffers. Check through the
        // public lookup API without exposing mutable storage to diagnostics.
        for milliseconds in [2_000, 2_100, 2_200, 2_300] {
            append(Int64(milliseconds))
        }
        guard store.frame(at: time(2_050)) == nil,
              hasTime(store.frame(at: time(2_100)), 2_100),
              hasTime(store.latestFrame(), 2_300) else {
            throw failure("摄像头缓存没有限制为最近三帧。")
        }
        store.clear()
    }

    private static func validateLayoutsAndMasks() throws {
        let camera = try buffer(size: CGSize(width: 160, height: 90), color: .blue)
        for canvasSize in [CGSize(width: 480, height: 270), CGSize(width: 270, height: 480)] {
            let source = try buffer(size: canvasSize, color: .white)
            let canvas = CGRect(origin: .zero, size: canvasSize)
            for position in CameraOverlayPosition.allCases {
                for size in CameraOverlaySize.allCases {
                    for shape in CameraOverlayShape.allCases {
                        let settings = CameraOverlaySettings(position: position, shape: shape, size: size)
                        let rect = settings.rect(in: canvasSize)
                        let margin = min(canvasSize.width, canvasSize.height) * 0.035
                        guard canvas.contains(rect),
                              abs(rect.width - rect.height) < 0.001,
                              abs(rect.width - min(canvasSize.width, canvasSize.height) * size.fraction) < 0.001,
                              abs(min(rect.minX, canvas.maxX - rect.maxX) - margin) < 0.001,
                              abs(min(rect.minY, canvas.maxY - rect.maxY) - margin) < 0.001 else {
                            throw failure("横竖画幅的人像尺寸或位置异常。")
                        }
                        switch position {
                        case .bottomRight:
                            guard rect.midX > canvas.midX, rect.midY < canvas.midY else {
                                throw failure("右下角人像坐标异常。")
                            }
                        case .bottomLeft:
                            guard rect.midX < canvas.midX, rect.midY < canvas.midY else {
                                throw failure("左下角人像坐标异常。")
                            }
                        case .topRight:
                            guard rect.midX > canvas.midX, rect.midY > canvas.midY else {
                                throw failure("右上角人像坐标异常。")
                            }
                        case .topLeft:
                            guard rect.midX < canvas.midX, rect.midY > canvas.midY else {
                                throw failure("左上角人像坐标异常。")
                            }
                        }
                        let destination = try buffer(size: canvasSize, color: .black)
                        FrameCompositor(mode: .browser, outputSize: canvasSize, cameraOverlay: settings)
                            .render(
                                source: source,
                                into: destination,
                                cameraFrame: CameraFrame(pixelBuffer: camera, presentationTime: .zero)
                            )
                        let center = pixel(destination, at: CGPoint(x: rect.midX, y: rect.midY))
                        let corner = pixel(destination, at: CGPoint(
                            x: rect.minX + rect.width * 0.02,
                            y: rect.minY + rect.height * 0.02
                        ))
                        let shapeProbe = pixel(destination, at: CGPoint(
                            x: rect.minX + rect.width * 0.12,
                            y: rect.minY + rect.height * 0.12
                        ))
                        let farAway = pixel(destination, at: CGPoint(x: canvas.midX, y: canvas.midY))
                        guard center.blue > 230, center.red < 20,
                              corner.red > 150, farAway.red > 245,
                              farAway.green > 245,
                              (shape == .rounded ? shapeProbe.red < 60 : shapeProbe.red > 120) else {
                            throw failure("人像形状裁切异常（\(position.rawValue)、\(shape.rawValue)、\(size.rawValue)）。")
                        }
                    }
                }
            }
        }

        let canvasSize = CGSize(width: 480, height: 320)
        let source = try buffer(size: canvasSize, color: .white)
        let destination = try buffer(size: canvasSize, color: .black)
        let settings = CameraOverlaySettings()
        let rect = settings.rect(in: canvasSize)
        FrameCompositor(mode: .display, outputSize: canvasSize, cameraOverlay: settings).render(
            source: source,
            into: destination,
            cameraFrame: CameraFrame(pixelBuffer: camera, presentationTime: .zero)
        )
        let shadow = pixel(destination, at: CGPoint(x: rect.midX, y: rect.minY - rect.width * 0.045))
        let border = pixel(destination, at: CGPoint(x: rect.minX + 0.3, y: rect.midY))
        let inner = pixel(destination, at: CGPoint(x: rect.minX + 5, y: rect.midY))
        guard shadow.red < 250, shadow.red > 165, border.red > inner.red + 15 else {
            throw failure("人像阴影或细描边异常（阴影 \(shadow)，描边 \(border)，内部 \(inner)）。")
        }
    }

    private static func validateMirrorAndLayerOrder() throws {
        let canvasSize = CGSize(width: 480, height: 320)
        let source = try buffer(size: canvasSize, color: .red)
        let cameraSize = CGSize(width: 160, height: 90)
        let camera = try buffer(size: cameraSize, color: .red)
        let right = CIImage(color: .blue).cropped(to: CGRect(x: 80, y: 0, width: 80, height: 90))
        let trimmedEdge = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 90))
        let cameraBackground = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: cameraSize))
        context.render(
            trimmedEdge.composited(over: right.composited(over: cameraBackground)),
            to: camera,
            bounds: CGRect(origin: .zero, size: cameraSize),
            colorSpace: colorSpace
        )
        for mirrored in [false, true] {
            let settings = CameraOverlaySettings(mirrored: mirrored)
            let rect = settings.rect(in: canvasSize)
            let destination = try buffer(size: canvasSize, color: .black)
            let compositor = FrameCompositor(
                mode: .region,
                outputSize: canvasSize,
                focusMask: CaptureFocusMask(
                    normalizedRect: CGRect(x: 0.05, y: 0.55, width: 0.25, height: 0.35),
                    cornerStyle: .rounded
                ),
                cameraOverlay: settings
            )
            compositor.render(
                source: source,
                into: destination,
                cameraFrame: CameraFrame(pixelBuffer: camera, presentationTime: .zero)
            )
            let left = pixel(destination, at: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY))
            let right = pixel(destination, at: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.midY))
            let expectedRed = mirrored ? right : left
            let expectedBlue = mirrored ? left : right
            let dimmedScreen = pixel(destination, at: CGPoint(x: 180, y: 150))
            guard expectedRed.red > 230, expectedRed.green < 20,
                  expectedBlue.blue > 230, expectedBlue.green < 20,
                  abs(dimmedScreen.red - dimmedScreen.green) < 12 else {
                throw failure("人像镜像、等比居中裁切或聚焦蒙版层级异常。")
            }
            let withoutCamera = try buffer(size: canvasSize, color: .black)
            compositor.render(source: source, into: withoutCamera)
            let noFrame = pixel(withoutCamera, at: CGPoint(x: rect.midX, y: rect.midY))
            guard abs(noFrame.red - noFrame.green) < 12 else {
                throw failure("摄像头缺帧时不应绘制额外人像区域。")
            }
        }
    }

    private static func validateStaticScreenAndPause() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapRecorder-camera-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let canvasSize = CGSize(width: 480, height: 320)
        let settings = CameraOverlaySettings(size: .large, mirrored: false)
        let source = try buffer(size: canvasSize, color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
        let redCamera = try buffer(size: CGSize(width: 160, height: 90), color: .red)
        let blueCamera = try buffer(size: CGSize(width: 160, height: 90), color: .blue)
        let writer = try RecordingWriter(
            outputURL: url,
            outputSize: canvasSize,
            mode: .display,
            capturesAudio: false,
            cameraOverlay: settings
        )
        var firstTime = CMTime.invalid
        var acceptedFrames = 0
        for _ in 0..<12 {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if writer.appendVideoFrame(source, at: now, cameraFrame: CameraFrame(pixelBuffer: redCamera, presentationTime: now)) {
                if !firstTime.isValid { firstTime = now }
                acceptedFrames += 1
            }
            try await Task.sleep(for: .milliseconds(34))
        }
        writer.pause()
        let pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
        guard !writer.appendVideoFrame(source, at: pauseStart, cameraFrame: CameraFrame(pixelBuffer: blueCamera, presentationTime: pauseStart)) else {
            throw failure("暂停期间写入了摄像头画面。")
        }
        try await Task.sleep(for: .milliseconds(240))
        let pauseEnd = CMClockGetTime(CMClockGetHostTimeClock())
        writer.resume()
        for _ in 0..<12 {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            if writer.appendVideoFrame(source, at: now, cameraFrame: CameraFrame(pixelBuffer: blueCamera, presentationTime: now)) {
                acceptedFrames += 1
            }
            try await Task.sleep(for: .milliseconds(34))
        }
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        try await writer.finish()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let expected = CMTimeSubtract(CMTimeSubtract(end, firstTime), CMTimeSubtract(pauseEnd, pauseStart)).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw failure("摄像头自检没有生成视频轨道。")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        guard reader.canAdd(output) else { throw failure("无法读取摄像头自检视频。") }
        reader.add(output)
        guard reader.startReading() else { throw failure("无法解码摄像头自检视频。") }
        let rect = settings.rect(in: canvasSize)
        var pixels: [Pixel] = []
        var previousTime = CMTime.invalid
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard !previousTime.isValid || CMTimeCompare(time, previousTime) > 0 else {
                throw failure("摄像头合成视频的时间戳没有递增。")
            }
            previousTime = time
            if let imageBuffer = CMSampleBufferGetImageBuffer(sample) {
                pixels.append(pixel(imageBuffer, at: CGPoint(x: rect.midX, y: rect.midY)))
            }
        }
        guard reader.status == .completed,
              acceptedFrames >= 20, pixels.count == acceptedFrames,
              let first = pixels.first, let last = pixels.last,
              first.red > 180, first.blue < 70,
              last.blue > 180, last.red < 70,
              abs(duration - expected) < 0.15 else {
            throw failure("静止屏幕人像更新或暂停时间异常（\(pixels.count)/\(acceptedFrames) 帧，\(duration)/\(expected) 秒）。")
        }
    }

    private struct Pixel: CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int
        var description: String { "\(red),\(green),\(blue)" }
    }

    private static func pixel(_ buffer: CVPixelBuffer, at point: CGPoint) -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { storage in
            context.render(
                CIImage(cvPixelBuffer: buffer),
                toBitmap: storage.baseAddress!,
                rowBytes: 4,
                bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return Pixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }

    private static func buffer(size: CGSize, color: CIColor) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &output
        )
        guard status == kCVReturnSuccess, let output else { throw failure("无法创建摄像头自检缓冲区。") }
        let bounds = CGRect(origin: .zero, size: size)
        context.render(CIImage(color: color).cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
        return output
    }

    private static func failure(_ message: String) -> CaptureError {
        .couldNotFinishWriter(message)
    }
}
