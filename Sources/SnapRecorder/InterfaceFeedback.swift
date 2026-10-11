import AVFoundation
import Foundation

enum RecorderDrawerSide {
    case left
    case right
}

enum DrawerMotion {
    /// A critically damped curve, normalized so the final frame is exact.
    static func progress(at time: Double) -> Double {
        let time = min(1, max(0, time))
        let damping = 8.0
        let settled = 1 - (1 + damping) * exp(-damping)
        return (1 - (1 + damping * time) * exp(-damping * time)) / settled
    }
}

/// Every channel state uses two unpunctuated Chinese lines, up to eight glyphs each.
enum ChannelDescriptions {
    static let systemAudio = "应用与网页声音\n一起录进视频"
    static let mouseOn = "光点跟随鼠标\n点击光晕扩散"
    static let mouseOff = "不录制鼠标\n画面不显示光标"
    static let cameraOff = "人像与屏幕\n一起录下来"
    static let cameraOn = "人像加入画面\n和屏幕一起录制"
    static let cameraPreparing = "正在准备摄像头\n请稍候片刻"
    static let cameraError = "摄像头暂不可用\n请检查系统设置"
    static let microphoneOff = "系统默认麦克风\n录制你的声音"
    static let microphoneOn = "录制你的声音\n合并或分轨导出"
    static let microphonePreparing = "正在申请权限\n请确认系统提示"
    static let microphoneError = "麦克风暂不可用\n请检查系统设置"
    static let microphoneUnavailable = "当前系统不支持\n请升级系统版本"
    static let all = [systemAudio, mouseOn, mouseOff, cameraOff, cameraOn,
                      cameraPreparing, cameraError, microphoneOff, microphoneOn,
                      microphonePreparing, microphoneError, microphoneUnavailable]
}

/// Short, locally synthesized electronic ticks. No capture session, permission,
/// network request or system alert sound is involved in playback.
@MainActor
final class CountdownSound {
    private var players: [Int: AVAudioPlayer] = [:]
    private var currentPlayer: AVAudioPlayer?

    func playTick(number: Int) {
        stop()
        let key = number == 1 ? 1 : 2
        if players[key] == nil {
            players[key] = try? AVAudioPlayer(data: Self.waveData(number: number))
            players[key]?.volume = 0.38
            players[key]?.prepareToPlay()
        }
        currentPlayer = players[key]
        currentPlayer?.currentTime = 0
        currentPlayer?.play()
    }

    func stop() {
        currentPlayer?.stop()
        currentPlayer = nil
    }

    nonisolated static func waveData(number: Int) -> Data {
        let sampleRate: UInt32 = 44_100
        let sampleCount = Int(Double(sampleRate) * 0.09)
        let frequency = number == 1 ? 1_400.0 : 1_050.0
        var data = Data()
        func appendInteger<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendInteger(UInt32(36 + sampleCount * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendInteger(UInt32(16))
        appendInteger(UInt16(1)) // Linear PCM.
        appendInteger(UInt16(1)) // Mono.
        appendInteger(sampleRate)
        appendInteger(sampleRate * 2)
        appendInteger(UInt16(2))
        appendInteger(UInt16(16))
        data.append(contentsOf: "data".utf8)
        appendInteger(UInt32(sampleCount * 2))
        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let attack = min(1, time / 0.002)
            let release = min(1, Double(sampleCount - 1 - index) / (Double(sampleRate) * 0.008))
            let envelope = attack * release * exp(-time * 38)
            let tone = sin(2 * .pi * frequency * time)
                + 0.2 * sin(2 * .pi * frequency * 2 * time)
            appendInteger(Int16(tone * envelope * 0.55 * Double(Int16.max)))
        }
        return data
    }
}

enum InterfaceFeedbackDiagnostics {
    static func run() throws -> String {
        try DisplayPresentationDiagnostics.run()
        for description in ChannelDescriptions.all {
            let lines = description.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count == 2, lines.allSatisfy({ !$0.isEmpty && $0.count <= 8 }),
                  lines.joined().unicodeScalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) else {
                throw CaptureError.couldNotFinishWriter("声音与画面说明未遵循两行中文排版。")
            }
        }
        guard InstrumentDrawerMetrics.width + 2 * InstrumentDrawerMetrics.inset == 378,
              InstrumentDrawerMetrics.height + 2 * InstrumentDrawerMetrics.inset == 560,
              InstrumentDrawerMetrics.footerHeight == 44 else {
            throw CaptureError.couldNotFinishWriter("左右抽屉的外框或操作区尺寸不一致。")
        }
        var previous = 0.0
        for step in 0...100 {
            let progress = DrawerMotion.progress(at: Double(step) / 100)
            guard progress >= previous, progress >= 0, progress <= 1 else {
                throw CaptureError.couldNotFinishWriter("抽屉缓动曲线不连续或超出边界。")
            }
            previous = progress
        }
        guard DrawerMotion.progress(at: 0) == 0, DrawerMotion.progress(at: 1) == 1,
              DrawerMotion.progress(at: 0.01) < 0.01,
              1 - DrawerMotion.progress(at: 0.99) < 0.001 else {
            throw CaptureError.couldNotFinishWriter("抽屉没有平滑起止。")
        }
        for number in [3, 2, 1] {
            let data = CountdownSound.waveData(number: number)
            let player = try AVAudioPlayer(data: data)
            guard abs(player.duration - 0.09) < 0.001, player.numberOfChannels == 1,
                  data.suffix(2) == Data([0, 0]), data.count > 44,
                  data.dropFirst(44).contains(where: { $0 != 0 }) else {
                throw CaptureError.couldNotFinishWriter("倒计时滴答音格式或淡出不正确。")
            }
        }
        guard CountdownSound.waveData(number: 1) != CountdownSound.waveData(number: 2) else {
            throw CaptureError.couldNotFinishWriter("倒计时最后一声没有使用开始提示音调。")
        }
        return "Shared drawer dimensions, damping, three countdown ticks, multi-display selection/placement and two-line Chinese channel descriptions passed."
    }
}
