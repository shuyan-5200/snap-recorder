import SwiftUI

/// Settings occupy a left drawer in the recorder's own window. The main panel
/// remains interactive and the drawer follows its movement and window level.
/// 视觉为“器物”规范里的铝面板：位置用四颗带灯的键，形状、大小、自然修饰用互锁键。
struct CameraOptionsView: View {
    @Binding var settings: CameraOverlaySettings
    var dismiss: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        InstrumentDrawer(title: "人像样式", showsCloseButton: false, closeLabel: "关闭人像样式", dismiss: dismiss) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                positionOptions
                InstrumentDrawerDivider()

                InstrumentDrawerField(title: "形状") {
                    InterlockKeys(
                        accessibilityTitle: "人像形状",
                        options: CameraOverlayShape.allCases,
                        selection: settings.shape,
                        title: \.title,
                        fills: true
                    ) { settings.shape = $0 }
                }
                InstrumentDrawerDivider()

                InstrumentDrawerField(title: "大小") {
                    InterlockKeys(
                        accessibilityTitle: "人像大小",
                        options: CameraOverlaySize.allCases,
                        selection: settings.size,
                        title: \.title,
                        fills: true
                    ) { settings.size = $0 }
                }
                InstrumentDrawerDivider()

                HStack {
                    EngravedLabel("镜像")
                    Spacer()
                    SlideSwitch("镜像", isOn: $settings.mirrored)
                }
                .frame(minHeight: 30)
                InstrumentDrawerDivider()

                InstrumentDrawerField(title: "自然修饰") {
                    InterlockKeys(
                        accessibilityTitle: "自然修饰",
                        options: CameraPortraitPreset.allCases,
                        selection: settings.portrait.preset,
                        title: \.title,
                        fills: true
                    ) { settings.portrait.preset = $0 }
                }
                .help("\(settings.portrait.preset.subtitle) 检测到正脸时生效；侧脸或遮挡时保留原图。")
            }
        } footer: {
            Button("完成", action: dismiss)
                .buttonStyle(KeyButtonStyle(kind: .dark))
                .keyboardShortcut(.defaultAction)
                .help("调整会同步到预览和最终录像。")
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onChange(of: isEnabled, initial: true) { _, enabled in hasKeyboardFocus = enabled }
        .onExitCommand(perform: dismiss)
    }

    private var positionOptions: some View {
        InstrumentDrawerField(title: "位置") {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    positionButton(.topLeft)
                    positionButton(.topRight)
                }
                HStack(spacing: 6) {
                    positionButton(.bottomLeft)
                    positionButton(.bottomRight)
                }
            }
        }
    }

    private func positionButton(_ position: CameraOverlayPosition) -> some View {
        let selected = settings.position == position
        return Button {
            settings.position = position
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: alignment(for: position)) {
                    DisplayWindowBackground(cornerRadius: 2)
                    LED(state: selected ? .lit : .off, size: 5)
                        .padding(2)
                }
                .frame(width: 30, height: 20)
                Text(position.title)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KeyButtonStyle(kind: .tile, isLatched: selected, fillsWidth: true))
        .accessibilityLabel("人像位置：\(position.title)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func alignment(for position: CameraOverlayPosition) -> Alignment {
        switch position {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}
