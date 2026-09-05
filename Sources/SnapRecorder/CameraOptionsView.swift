import SwiftUI

/// Settings stay inside the recorder window, so region-mode window levels cannot
/// leave a separate popover behind the recorder or the capture overlay.
struct CameraOptionsView: View {
    @Binding var settings: CameraOverlaySettings
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "video.fill")
                    .foregroundStyle(.pink)
                Text("人像样式")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭人像样式")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    positionOptions

                    VStack(alignment: .leading, spacing: 7) {
                        sectionLabel("形状")
                        Picker("人像形状", selection: $settings.shape) {
                            ForEach(CameraOverlayShape.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        sectionLabel("大小")
                        Picker("人像大小", selection: $settings.size) {
                            ForEach(CameraOverlaySize.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Toggle("镜像", isOn: $settings.mirrored)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 12))

                    Divider().overlay(.white.opacity(0.06))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("自然修饰")
                            .font(.system(size: 12, weight: .medium))
                        Picker("自然修饰", selection: $settings.portrait.preset) {
                            ForEach(CameraPortraitPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(settings.portrait.preset.subtitle)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("检测到正脸时生效；侧脸或遮挡时保留原图。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: 384)

            VStack(spacing: 10) {
                Text("调整会同步到预览和最终录像。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("完成", action: dismiss)
                    .buttonStyle(SnapPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .frame(width: 354)
        .background(Color(red: 0.12, green: 0.12, blue: 0.17), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 25, y: 10)
        .onExitCommand(perform: dismiss)
    }

    private var positionOptions: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("位置")
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
            HStack(spacing: 9) {
                ZStack(alignment: alignment(for: position)) {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(selected ? Color.pink : .white.opacity(0.5))
                        .frame(width: 9, height: 9)
                        .padding(4)
                }
                .frame(width: 35, height: 25)
                Text(position.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 43)
            .background(selected ? Color.pink.opacity(0.13) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.pink.opacity(0.55) : Color.white.opacity(0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // A plain button otherwise only hits its drawn subviews, leaving
            // the empty center of the miniature screen and padding unreliable.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("人像位置：\(position.title)")
        .accessibilityValue(selected ? "已选择" : "未选择")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
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
