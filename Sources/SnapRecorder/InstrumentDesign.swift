import AppKit
import SwiftUI

// “器物”视觉规范的令牌与部件。数值与 `视觉规范/器物/index.html` 一一对应，
// 1pt 对应规范里的 1px；历史视觉探索不参与产品构建。
// 光从上方来：亮边在上、阴影在下。信号橙只用于录制。

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Instrument {
    // 机身
    static let alu = Color(hex: 0xD4D2CD)
    static let aluHi = Color(hex: 0xE6E4DF)
    static let aluLo = Color(hex: 0xC6C4BE)
    static let groove = Color(hex: 0xA8A6A0)

    // 字
    static let graphite = Color(hex: 0x232322)
    static let ink2 = Color(hex: 0x434240)
    static let buttonText = Color(hex: 0x333330)
    static let engrave = Color(hex: 0x555350)
    static let disabled = Color(hex: 0x8E8C86)

    // 显示窗
    static let window = Color(hex: 0x1B1C1B)
    static let readout = Color(hex: 0xEFEAE0)
    static let readoutDim = Color(hex: 0x9A968D)

    // 信号与状态
    static let signal = Color(hex: 0xEE5A24)
    static let signalDeep = Color(hex: 0xB8430F)
    static let ledOn = Color(hex: 0xA8EB8A)
    static let ledGlow = ledOn.opacity(0.6)
    static let ledOff = Color(hex: 0x75736E)
    static let ledRing = Color(hex: 0x3A3936)
    static let warn = Color(hex: 0x7A4300)
    static let ok = Color(hex: 0x2A5E39)

    static let actionHeight: CGFloat = 44
    static let channelIndicatorSpacing: CGFloat = 5

    /// 暗色键上的暖白字。
    static let darkKeyText = Color(hex: 0xF4F2EE)

    // Interface text grows together; primary action captions retain their size.
    static let interfaceTextIncrement: CGFloat = 1
    static func textSize(_ size: CGFloat) -> CGFloat { size + interfaceTextIncrement }
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: textSize(size), weight: weight)
    }
    static func din(_ size: CGFloat) -> Font { .custom("DINAlternate-Bold", size: textSize(size)) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular, adjustsForInterface: Bool = true) -> Font {
        .system(size: adjustsForInterface ? textSize(size) : size, weight: weight, design: .monospaced)
    }

    enum Motion {
        /// 按键：下沉 1pt，80ms 缓出。
        static let key = Animation.easeOut(duration: 0.08)
        /// 拨杆、互锁键、滑块：160ms。
        static let slide = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.16)
        /// 旋钮：220ms，轻微回弹。
        static let knob = Animation.timingCurve(0.3, 1.4, 0.5, 1, duration: 0.22)
    }
}

// MARK: - 材质

/// 拉丝铝：底色叠极淡的横向拉丝纹（亮 5%、暗 2%）与自上而下的明暗过渡。
struct BrushedAluminum: View {
    var base: Color = Instrument.alu
    var bevel = true

    var body: some View {
        ZStack {
            base
            BrushLines()
            if bevel {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.32), location: 0),
                        .init(color: .white.opacity(0), location: 0.38),
                        .init(color: .black.opacity(0.04), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BrushLines: View {
    var body: some View {
        Canvas { context, size in
            var light = Path()
            var dark = Path()
            var y: CGFloat = 0
            while y < size.height {
                light.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                dark.addRect(CGRect(x: 0, y: y + 1, width: size.width, height: 1))
                y += 2
            }
            context.fill(light, with: .color(.white.opacity(0.05)))
            context.fill(dark, with: .color(.black.opacity(0.022)))
        }
    }
}

/// 模块之间的机加工刻线：1pt 黑 14% 暗线 + 1pt 白 55% 亮线。
struct Groove: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.black.opacity(0.14)).frame(height: 1)
            Rectangle().fill(Color.white.opacity(0.55)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// 行与行之间的细分隔：1pt 黑 10% + 1pt 白 50%。
struct RowSeparator: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.black.opacity(0.1)).frame(height: 1)
            Rectangle().fill(Color.white.opacity(0.5)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// 内阴影：沿形状边缘描一圈模糊的暗边，再裁回形状内部。
struct InnerShadow<S: InsettableShape>: View {
    let shape: S
    var color: Color
    var radius: CGFloat
    var y: CGFloat

    var body: some View {
        shape
            .stroke(color, lineWidth: radius * 2 + 1)
            .blur(radius: radius)
            .offset(y: y)
            .mask(shape)
            .allowsHitTesting(false)
    }
}

/// 深色显示窗：#1B1C1B 内凹，内阴影 0 1 3 / 60%，上缘 6% 反光，下缘一道亮边。
struct DisplayWindowBackground: View {
    var cornerRadius: CGFloat = 3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Instrument.window)
            .overlay {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.06), location: 0),
                            .init(color: .white.opacity(0), location: 0.4)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .overlay { InnerShadow(shape: shape, color: .black.opacity(0.6), radius: 1.5, y: 1) }
            .background { shape.fill(Color.white.opacity(0.55)).offset(y: 1) }
            .accessibilityHidden(true)
    }
}

/// 铝面板：拉丝铝 + 刻线描边 + 上缘高光。浮窗、人像样式面板使用。
struct AluminumPanelBackground: View {
    var cornerRadius: CGFloat = 10
    var borderOpacity: Double = 0.3

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        BrushedAluminum()
            .clipShape(shape)
            .overlay {
                shape.inset(by: 1).strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.75), location: 0),
                            .init(color: .white.opacity(0), location: 0.06)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .overlay { shape.strokeBorder(Instrument.graphite.opacity(borderOpacity), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

// MARK: - 指示灯、螺钉、键帽

/// 6pt 圆灯嵌在深色灯圈里；亮起时外发同色光晕。
struct LED: View {
    enum Tone { case off, lit, rec, dim }

    var state: Tone
    var size: CGFloat = 6

    var body: some View {
        ZStack {
            if state == .lit || state == .rec {
                Circle()
                    .fill(glow)
                    .frame(width: size + 6, height: size + 6)
                    .blur(radius: 2.5)
            }
            Circle()
                .fill(state == .dim ? Color(hex: 0x3A3936, opacity: 0.4) : Instrument.ledRing)
                .frame(width: size + 3, height: size + 3)
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
        }
        .frame(width: size + 3, height: size + 3)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch state {
        case .off: Instrument.ledOff
        case .lit: Instrument.ledOn
        case .rec: Instrument.signal
        case .dim: Color(hex: 0x9D9B95)
        }
    }

    private var glow: Color {
        state == .rec ? Instrument.signal.opacity(0.5) : Instrument.ledGlow
    }
}

struct Screw: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(hex: 0xF4F3F0), Color(hex: 0xA8A6A0)],
                    center: UnitPoint(x: 0.35, y: 0.35),
                    startRadius: 0,
                    endRadius: size * 0.75
                )
            )
            .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5) }
            .overlay {
                Rectangle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: size - 3, height: 1)
                    .rotationEffect(.degrees(35))
            }
            .background { Circle().fill(Color.white.opacity(0.6)).offset(y: 1) }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 刻在键上的快捷键：1pt 刻线边、SF Mono 10。
struct KeyCap: View {
    let text: String
    var keepsOriginalTextSize = false
    var color: Color = Instrument.ink2
    var border: Color = Instrument.graphite.opacity(0.3)
    /// 行内提示里的小号键帽：高 16、SF Mono 9.5。
    var compact = false

    var body: some View {
        label
            .font(Instrument.mono(compact ? 9.5 : 10, weight: .medium, adjustsForInterface: !keepsOriginalTextSize))
            .foregroundStyle(color)
            .padding(.leading, compact ? 4 : 5)
            .padding(.trailing, isCommandShortcut ? (compact ? 3 : 4) : (compact ? 4 : 5))
            .frame(height: compact ? 16 : 18)
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private var label: some View {
        if isCommandShortcut {
            HStack(spacing: 2) {
                Text("⌘")
                Text(String(text.dropFirst()))
            }
        } else {
            Text(text)
        }
    }

    private var isCommandShortcut: Bool {
        text.hasPrefix("⌘") && text.count > 1
    }
}

/// 模块刻字：苹方 500 · 12 / 15 · 字距 0.16em，下缘一道亮边像刻进铝面。
struct EngravedLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Instrument.text(11, weight: .medium))
            .tracking(Instrument.textSize(11) * 0.16)
            .foregroundStyle(Instrument.engrave)
            .shadow(color: .white.opacity(0.55), radius: 0, x: 0, y: 1)
            .frame(height: 15)
    }
}

/// 主面板铭牌：铝亮底、两枚螺钉、DIN 大写字名与标语。
struct Nameplate: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 12) {
            Screw()
            Text("SNAP RECORDER")
                .font(Instrument.din(14))
                .tracking(14 * 0.24)
                .foregroundStyle(Instrument.graphite)
                .accessibilityLabel("Snap Recorder")
            Spacer(minLength: 8)
            Text("极简录制，高清保存")
                .font(Instrument.text(10.5))
                .tracking(10.5 * 0.08)
                .foregroundStyle(Instrument.engrave)
            Screw()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background {
            BrushedAluminum(base: Instrument.aluHi, bevel: false)
                .clipShape(shape)
                .overlay {
                    shape.inset(by: 0.5).stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.85), location: 0),
                                .init(color: .white.opacity(0), location: 0.1),
                                .init(color: .black.opacity(0), location: 0.9),
                                .init(color: .black.opacity(0.08), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 实体键

struct KeyButtonStyle: ButtonStyle {
    enum Kind {
        /// 普通键：高 32，圆角 6。
        case regular
        /// 小键：高 24，圆角 3，通道里的附属操作。
        case small
        /// 图标键：28 × 28。
        case icon
        /// 大操作旁的方形图标键：44 × 44，与保存键等高。
        case actionIcon
        /// 带文字的次要操作：与保存键等高，沿用浅色实体键。
        case secondaryAction
        /// 控制条上的键：30 × 30。
        case hud
        /// 互锁键：高 30，圆角 6，带灯。
        case segment
        /// 迷你互锁键：高 22，圆角 3。
        case segmentMini
        /// 比例键：高 46，圆角 3。
        case ratio
        /// 方键：高 40，圆角 6，人像位置等带图示的选项。
        case tile
        /// 显示器编号：28 × 28，与刷新键同尺寸，点击区为 40 × 40。
        case displayNumber
        /// 深色大键：高 44，圆角 10，确认动作。
        case dark
        /// 录制键：高 44，与保存键一致；圆角 10，整块面板唯一的橙色。
        case record
    }

    var kind: Kind = .regular
    /// 锁住的键（选中、已勾选）保持按下的外观。
    var isLatched = false
    var fillsWidth: Bool?

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            kind: kind,
            isLatched: isLatched,
            fillsWidth: fillsWidth ?? (kind == .dark || kind == .record)
        )
    }
}

private struct KeyBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let kind: KeyButtonStyle.Kind
    let isLatched: Bool
    let fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var down: Bool { isEnabled && (isPressed || isLatched) }

    @ViewBuilder
    var body: some View {
        if kind == .displayNumber {
            key.frame(width: 40, height: 40).contentShape(Rectangle())
        } else {
            key
        }
    }

    private var key: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(textColor)
            .padding(.horizontal, padding)
            .frame(width: fixedWidth, height: height)
            .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil)
            .background { shape.fill(face) }
            .overlay {
                if down {
                    InnerShadow(shape: shape, color: pressedShadow, radius: 1.5, y: 1)
                } else if isEnabled {
                    shape.inset(by: 1).strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(highlight), location: 0),
                                .init(color: .white.opacity(0), location: min(1, 3 / height))
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
            }
            .overlay { shape.strokeBorder(borderColor, lineWidth: 1) }
            .contentShape(shape)
            .offset(y: down ? 1 : 0)
            .background {
                if isEnabled, !down {
                    shape
                        .fill(sideColor)
                        .offset(y: side)
                        .shadow(color: dropColor, radius: dropRadius, y: dropY)
                }
            }
            .animation(reduceMotion ? nil : Instrument.Motion.key, value: down)
            .onHover { isHovering = $0 }
    }

    private var height: CGFloat {
        switch kind {
        case .regular: 32
        case .small: 24
        case .icon: 28
        case .actionIcon, .secondaryAction: Instrument.actionHeight
        case .hud: 30
        case .segment: 30
        case .segmentMini: 22
        case .ratio: 46
        case .tile: 40
        case .displayNumber: 28
        case .dark, .record: Instrument.actionHeight
        }
    }

    private var fixedWidth: CGFloat? {
        switch kind {
        case .icon: 28
        case .actionIcon: Instrument.actionHeight
        case .hud: 30
        case .displayNumber: 28
        default: nil
        }
    }

    private var minWidth: CGFloat? { kind == .segment && !fillsWidth ? 64 : nil }

    private var padding: CGFloat {
        switch kind {
        case .regular: 14
        case .small: 9
        case .icon, .actionIcon, .hud, .ratio, .displayNumber: 0
        case .segment: 12
        case .segmentMini: 8
        case .tile: 10
        case .secondaryAction: 10
        case .dark, .record: 16
        }
    }

    private var radius: CGFloat {
        switch kind {
        case .small, .segmentMini, .ratio: 3
        case .regular, .icon, .hud, .segment, .tile, .displayNumber: 6
        case .dark, .record, .actionIcon, .secondaryAction: 10
        }
    }

    private var font: Font {
        switch kind {
        case .dark, .record: .system(size: 15, weight: .semibold)
        case .segmentMini: Instrument.text(11, weight: .semibold)
        case .ratio: Instrument.din(11)
        default: Instrument.text(12, weight: .semibold)
        }
    }

    private var side: CGFloat { kind == .small || kind == .segmentMini ? 1 : 2 }

    private var face: AnyShapeStyle {
        guard isEnabled else { return AnyShapeStyle(Instrument.aluLo) }
        switch kind {
        case .dark:
            if down { return AnyShapeStyle(Instrument.graphite) }
            return AnyShapeStyle(vertical(isHovering ? 0x454543 : 0x3A3A38, isHovering ? 0x2E2E2D : 0x262625))
        case .record:
            if down { return AnyShapeStyle(Instrument.signal) }
            return AnyShapeStyle(vertical(isHovering ? 0xF47A4C : 0xF27040, isHovering ? 0xF06430 : 0xEE5A24))
        default:
            if down { return AnyShapeStyle(vertical(0xD4D2CD, 0xCBC9C4)) }
            return AnyShapeStyle(vertical(isHovering ? 0xF4F2EE : 0xEEECE8, isHovering ? 0xE3E1DC : 0xDEDCD7))
        }
    }

    private var textColor: Color {
        guard isEnabled else { return Instrument.disabled }
        switch kind {
        case .dark: return Instrument.darkKeyText
        case .segment, .segmentMini, .tile: return down ? Instrument.buttonText : Instrument.ink2
        case .ratio: return down ? Instrument.buttonText : (isHovering ? Instrument.ink2 : Instrument.engrave)
        default: return Instrument.buttonText
        }
    }

    private var borderColor: Color {
        switch kind {
        case .dark: isEnabled ? Color(hex: 0x111111) : Instrument.graphite.opacity(0.2)
        case .record: isEnabled ? Color(hex: 0x782808, opacity: 0.55) : Instrument.graphite.opacity(0.2)
        default: Instrument.graphite.opacity(0.26)
        }
    }

    private var highlight: Double {
        switch kind {
        case .dark: 0.14
        case .record: 0.35
        default: 0.85
        }
    }

    private var pressedShadow: Color {
        switch kind {
        case .dark: .black.opacity(0.5)
        case .record: Color(hex: 0x5A1E05, opacity: 0.45)
        default: .black.opacity(0.24)
        }
    }

    private var sideColor: Color {
        switch kind {
        case .dark: Color(hex: 0x121211)
        case .record: Instrument.signalDeep
        default: Instrument.groove
        }
    }

    private var dropColor: Color {
        switch kind {
        case .dark: .black.opacity(0.25)
        case .record: Color(hex: 0xB8430F, opacity: 0.3)
        case .small, .segmentMini: .black.opacity(0.14)
        default: .black.opacity(0.16)
        }
    }

    private var dropRadius: CGFloat {
        switch kind {
        case .dark: 4
        case .record: 5
        case .small, .segmentMini, .segment, .ratio, .tile: 2
        default: 3
        }
    }

    private var dropY: CGFloat { kind == .small || kind == .segmentMini ? 1 : 2 }

    private func vertical(_ top: UInt32, _ bottom: UInt32) -> LinearGradient {
        LinearGradient(colors: [Color(hex: top), Color(hex: bottom)], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 拨杆

/// 滑槽拨杆：左侧指示灯 + 深色矩形槽 36 × 20（圆角 6）+ 铝钮 16 × 14（圆角 3），四周留 3，与槽同心。
/// 推到右侧为开（行程 14），指示灯同时亮起。
struct SlideSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var isBusy = false
    var indicatorSpacing: CGFloat = 3

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, isOn: Binding<Bool>, isBusy: Bool = false, indicatorSpacing: CGFloat = 3) {
        self.title = title
        _isOn = isOn
        self.isBusy = isBusy
        self.indicatorSpacing = indicatorSpacing
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: indicatorSpacing) {
                LED(state: isOn ? .lit : .off)
                ZStack(alignment: .leading) {
                    slot
                    SliderCap(width: 16, height: 14, vertical: true)
                        .offset(x: isOn ? 17 : 3)
                }
                .frame(width: 36, height: 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? (isBusy ? 0.6 : 1) : 0.4)
        .animation(reduceMotion ? nil : Instrument.Motion.slide, value: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(.isToggle)
    }

    private var slot: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return shape
            .fill(Instrument.ledRing)
            .overlay { InnerShadow(shape: shape, color: .black.opacity(0.55), radius: 1.5, y: 1) }
            .background { shape.fill(Color.white.opacity(0.55)).offset(y: 1) }
    }
}

/// 铝钮：拨杆钮上亮下暗；滑块钮横向像圆柱。三道防滑纹。
struct SliderCap: View {
    var width: CGFloat
    var height: CGFloat
    var vertical: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        shape
            .fill(
                vertical
                    ? LinearGradient(colors: [Color(hex: 0xF4F2EE), Color(hex: 0xD4D2CD)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0xCFCDC8), location: 0),
                            .init(color: Color(hex: 0xF2F0EC), location: 0.45),
                            .init(color: Color(hex: 0xC9C7C1), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
            )
            .overlay {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(Color.black.opacity(0.2)).frame(width: 1, height: 8)
                    }
                }
            }
            .overlay {
                if vertical {
                    shape.inset(by: 0.5).stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.9), location: 0),
                                .init(color: .white.opacity(0), location: 0.15)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
            }
            .overlay { shape.strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5) }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - 锁定键与互锁键

/// 能锁住的键：按下后下沉、灯亮；再按弹起。未录制的内容键面置灰、灯不亮、不能按。
struct LatchKey: View {
    let title: String
    let isOn: Bool
    var fillsWidth = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                LED(state: isEnabled ? (isOn ? .lit : .off) : .dim)
                Text(title)
            }
        }
        .buttonStyle(KeyButtonStyle(kind: .segment, isLatched: isOn, fillsWidth: fillsWidth))
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已选" : "未选")
        .accessibilityAddTraits(.isToggle)
    }
}

/// 相邻的互锁键：按下一颗，另一颗弹起；按下的键带亮灯。
struct InterlockKeys<Option: Hashable>: View {
    let accessibilityTitle: String
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    var mini = false
    var fills = false
    let select: (Option) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    select(option)
                } label: {
                    HStack(spacing: 6) {
                        LED(state: selected ? .lit : .off, size: mini ? 4 : 5)
                        Text(title(option))
                    }
                }
                .buttonStyle(KeyButtonStyle(kind: mini ? .segmentMini : .segment, isLatched: selected, fillsWidth: fills))
                .accessibilityLabel(title(option))
                .accessibilityValue(selected ? "已选" : "未选")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .onMoveCommand { direction in
            guard let index = options.firstIndex(of: selection) else { return }
            switch direction {
            case .left where index > 0: select(options[index - 1])
            case .right where index < options.count - 1: select(options[index + 1])
            default: break
            }
        }
    }
}

// MARK: - 旋钮

/// 来源旋钮：56，滚花外圈、铝帽、石墨指针。
struct SourceKnob: View {
    let angle: Angle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                for index in 0..<90 {
                    var wedge = Path()
                    wedge.move(to: center)
                    wedge.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(Double(index) * 4),
                        endAngle: .degrees(Double(index + 1) * 4),
                        clockwise: false
                    )
                    wedge.closeSubpath()
                    context.fill(wedge, with: .color(Color(hex: index.isMultiple(of: 2) ? 0xBDBBB5 : 0xDAD8D3)))
                }
            }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1) }

            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color(hex: 0xF5F4F1), location: 0),
                            .init(color: Color(hex: 0xCFCDC8), location: 0.6),
                            .init(color: Color(hex: 0xB9B7B1), location: 1)
                        ],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: 40
                    )
                )
                .overlay {
                    Circle().inset(by: 0.5).stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.85), location: 0),
                                .init(color: .white.opacity(0), location: 0.2)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                .padding(6)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Instrument.graphite)
                .frame(width: 21, height: 3)
                .frame(width: 42, alignment: .trailing)
                .rotationEffect(angle)
                .animation(reduceMotion ? nil : Instrument.Motion.knob, value: angle)
        }
        .frame(width: 56, height: 56)
        .background {
            Circle()
                .fill(Instrument.groove)
                .offset(y: 2)
                .shadow(color: .black.opacity(0.22), radius: 4, y: 3)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 比例键图形

struct RatioGlyph: View {
    let aspectRatio: CaptureAspectRatio

    var body: some View {
        let size = glyphSize
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .stroke(
                style: StrokeStyle(lineWidth: 1.25, dash: aspectRatio == .custom ? [2.5, 1.5] : [])
            )
            .frame(width: size.width, height: size.height)
            .frame(width: 24, height: 16)
            .accessibilityHidden(true)
    }

    /// 按真实比例绘制，与规范里的比例键一致。
    private var glyphSize: CGSize {
        switch aspectRatio {
        case .widescreen: CGSize(width: 20, height: 11.3)
        case .portrait: CGSize(width: 8.4, height: 15)
        case .standard: CGSize(width: 18, height: 13.5)
        case .portraitStandard: CGSize(width: 11, height: 14.7)
        case .ultrawide: CGSize(width: 22, height: 9.4)
        case .square: CGSize(width: 14, height: 14)
        case .custom: CGSize(width: 18, height: 12)
        }
    }
}

// MARK: - 五挡滑块

/// 深色轨道配五道刻度，铝钮停在当前挡位；挡位名写在刻度下方。
struct FivePositionSlider<Option: Hashable>: View {
    let accessibilityTitle: String
    let options: [Option]
    let selection: Option
    let title: (Option) -> String
    let help: (Option) -> String
    let select: (Option) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedIndex: Int { options.firstIndex(of: selection) ?? 0 }

    var body: some View {
        VStack(spacing: 4) {
            trackControl

            GeometryReader { proxy in
                let width = proxy.size.width
                let inset = trackInset(for: width)
                let steps = CGFloat(max(1, options.count - 1))
                let stepWidth = max(0, width - 2 * inset) / steps
                ForEach(Array(options.enumerated()), id: \.element) { index, option in
                    let selected = option == selection
                    let atEdge = index == 0 || index == options.count - 1
                    Button {
                        select(option)
                    } label: {
                        Text(title(option))
                            .font(Instrument.text(11.5, weight: selected ? .bold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(selected ? Instrument.buttonText : Instrument.engrave)
                            .frame(width: atEdge ? 2 * inset : stepWidth, height: 22, alignment: .top)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help(option))
                    .accessibilityLabel(title(option))
                    .accessibilityValue(selected ? "已选" : "未选")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .position(x: inset + stepWidth * CGFloat(index), y: 11)
                }
            }
            .frame(height: 22)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
        .onMoveCommand { direction in
            switch direction {
            case .left where selectedIndex > 0: select(options[selectedIndex - 1])
            case .right where selectedIndex < options.count - 1: select(options[selectedIndex + 1])
            default: break
            }
        }
    }

    // Just enough room for the end labels; ticks, thumb and labels share anchors.
    private func trackInset(for width: CGFloat) -> CGFloat { min(19, width / 2) }

    private var trackControl: some View {
        GeometryReader { proxy in
                let width = proxy.size.width
                let trackStart = trackInset(for: width)
                let trackWidth = max(0, width - 2 * trackStart)
                let steps = CGFloat(max(1, options.count - 1))
                ZStack(alignment: .topLeading) {
                    let track = RoundedRectangle(cornerRadius: 3, style: .continuous)
                    track
                        .fill(Instrument.ledRing)
                        .overlay { InnerShadow(shape: track, color: .black.opacity(0.6), radius: 1, y: 1) }
                        .background { track.fill(Color.white.opacity(0.55)).offset(y: 1) }
                        .frame(width: trackWidth, height: 6)
                        .offset(x: trackStart, y: 6)

                    ForEach(0..<options.count, id: \.self) { index in
                        Rectangle()
                            .fill(Instrument.groove)
                            .frame(width: 1, height: 5)
                            .offset(x: trackStart + trackWidth * CGFloat(index) / steps - 0.5, y: 15)
                    }

                    SliderCap(width: 18, height: 14, vertical: false)
                        .offset(x: trackStart + trackWidth * CGFloat(selectedIndex) / steps - 9, y: 2)
                        .animation(reduceMotion ? nil : Instrument.Motion.slide, value: selectedIndex)
                }
                .frame(width: width, height: 22, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !options.isEmpty, trackWidth > 0 else { return }
                            let position = (value.location.x - trackStart) / trackWidth
                            let index = min(options.count - 1, max(0, Int((position * steps).rounded())))
                            if index != selectedIndex { select(options[index]) }
                        }
                )
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - 点阵读数与走马灯

/// 会跳动的读数：SF Mono 粗体叠点阵遮罩。
struct DotMatrixText: View {
    let text: String
    var size: CGFloat
    var pitch: CGFloat = 2
    var color: Color = Instrument.readout

    var body: some View {
        Text(text)
            .font(Instrument.mono(size, weight: .bold))
            .monospacedDigit()
            .tracking(size * 0.06)
            .foregroundStyle(color)
            .mask { DotGrid(pitch: pitch) }
    }
}

private struct DotGrid: View {
    let pitch: CGFloat

    var body: some View {
        Canvas { context, size in
            let radius = pitch * 0.44
            var dots = Path()
            var y = pitch / 2
            while y < size.height + pitch {
                var x = pitch / 2
                while x < size.width + pitch {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += pitch
                }
                y += pitch
            }
            context.fill(dots, with: .color(.black))
        }
    }
}

/// 导出中：一排十盏灯依次走马，1.2 秒一圈；减少动态效果时只亮第一盏。
struct ChaserLights: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let litIndex = reduceMotion ? 0 : min(9, Int(phase * 10))
            HStack(spacing: 6) {
                ForEach(0..<10, id: \.self) { index in
                    Circle()
                        .fill(index == litIndex ? Instrument.ledOn : Color(hex: 0x3F3E3B))
                        .frame(width: 7, height: 7)
                        .shadow(color: index == litIndex ? Instrument.ledGlow : .clear, radius: 2)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background { DisplayWindowBackground() }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 凹槽输入

/// 铝亮底内凹、1pt 刻线边；聚焦时外圈 2pt 石墨；出错时边线转警示色。
struct GrooveField: ViewModifier {
    var isInvalid = false
    var monospaced = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(monospaced ? Instrument.mono(12.5) : Instrument.text(12.5))
            .foregroundStyle(isEnabled ? Instrument.graphite : Instrument.disabled)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                shape
                    .fill(isEnabled ? Instrument.aluHi : Instrument.aluLo)
                    .overlay { InnerShadow(shape: shape, color: .black.opacity(isEnabled ? 0.14 : 0.08), radius: 1, y: 1) }
            }
            .overlay {
                shape.strokeBorder(isEnabled && isInvalid ? Instrument.warn : Instrument.graphite.opacity(isEnabled ? 0.24 : 0.14), lineWidth: 1)
            }
            .overlay {
                if isEnabled && isInvalid {
                    shape.inset(by: -1).strokeBorder(Instrument.warn, lineWidth: 1)
                }
            }
            .overlay {
                if isEnabled && isFocused {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Instrument.graphite, lineWidth: 2)
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// 文字链接：次石墨字，悬停时加下划线。
struct LinkTextButtonStyle: ButtonStyle {
    var size: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        LinkTextBody(label: configuration.label, isPressed: configuration.isPressed, size: size)
    }
}

private struct LinkTextBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let size: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        label
            .font(Instrument.text(size, weight: .medium))
            .foregroundStyle(isEnabled ? (isPressed ? Instrument.buttonText : Instrument.ink2) : Instrument.disabled)
            .underline(isHovering && isEnabled)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

extension View {
    func grooveField(isInvalid: Bool = false, monospaced: Bool = false) -> some View {
        modifier(GrooveField(isInvalid: isInvalid, monospaced: monospaced))
    }
}
