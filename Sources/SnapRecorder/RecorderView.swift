import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.075, green: 0.085, blue: 0.13),
                    Color(red: 0.11, green: 0.08, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.purple.opacity(0.16))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: 220, y: -180)

            content
                .padding(28)
        }
        .frame(width: 560, height: 440)
        .preferredColorScheme(.dark)
        .onAppear {
            if model.permissionGranted {
                Task { await model.refreshBrowserWindows() }
            }
        }
        .onChange(of: model.mode) { _, newValue in
            if newValue == .browser, model.permissionGranted {
                Task { await model.refreshBrowserWindows() }
            }
        }
        .onChange(of: model.selectedBrowserWindowID) { _, newValue in
            if newValue != nil {
                model.browserSelectionNote = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .countdown, .recording, .paused:
            if model.permissionGranted {
                setupView
            } else {
                permissionView
            }
        case .preparingExport, .exporting:
            exportingView
        case .choosingExport:
            exportChoiceView
        case .finished:
            finishedView
        case .failed:
            failedView
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.9, green: 0.28, blue: 0.42), .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Snap Recorder")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("极简录制，高清保存")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var permissionView: some View {
        VStack(spacing: 0) {
            header
            Spacer()

            VStack(spacing: 15) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.pink, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("开始你的第一次录屏")
                    .font(.system(size: 22, weight: .semibold))

                Text("需要 macOS 的屏幕录制权限。视频只在这台 Mac 上处理，完成后自动保存到“下载”。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
                    .lineSpacing(4)

                Button("允许屏幕录制") {
                    model.requestPermission()
                }
                .buttonStyle(SnapPrimaryButtonStyle())
                .frame(width: 210)

                if model.hasRequestedPermission {
                    VStack(spacing: 5) {
                        Button("打开系统设置") {
                            model.openScreenRecordingSettings()
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(.secondary)

                        Text("已经允许但仍未生效时，请退出并重新打开 Snap Recorder。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
            Text("Snap Recorder 不上传录屏，也不会录入自己的控制界面")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var setupView: some View {
        VStack(spacing: 14) {
            header

            Picker("录制来源", selection: $model.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            sourceCard

            soundControls

            Button {
                model.startRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle")
                    Text("开始录制")
                }
            }
            .buttonStyle(SnapPrimaryButtonStyle())
            .disabled(!model.canStartRecording)
        }
    }

    private var soundControls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("电脑声音")
                        .font(.system(size: 13, weight: .medium))
                    Text("应用与网页声音")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: $model.capturesSystemAudio)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .frame(height: 36)

            Divider()
                .overlay(Color.white.opacity(0.08))

            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("人声（麦克风）")
                        .font(.system(size: 13, weight: .medium))
                    Text(microphoneSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(model.microphoneMessage == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                }
                Spacer()

                if model.microphoneMessage != nil, model.microphoneFeatureAvailable {
                    Button("打开设置") {
                        model.openMicrophoneSettings()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                if model.isRequestingMicrophonePermission {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30)
                } else {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.capturesMicrophone },
                            set: { model.setMicrophoneCaptureEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!model.microphoneFeatureAvailable)
                }
            }
            .frame(height: 36)
        }
        .padding(.horizontal, 13)
        .background(cardBackground)
    }

    private var microphoneSubtitle: String {
        if let message = model.microphoneMessage { return message }
        if !model.microphoneFeatureAvailable { return "需要 macOS 15 或更高版本" }
        return model.capturesMicrophone ? "结束后可合并或分开导出" : "使用系统默认麦克风"
    }

    @ViewBuilder
    private var sourceCard: some View {
        if model.mode == .browser {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("选择一个浏览器窗口", systemImage: "safari.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        Task { await model.refreshBrowserWindows() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("刷新窗口")
                }

                if model.isLoadingWindows {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在读取浏览器窗口…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                } else if let browserListError = model.browserListError {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("读取浏览器窗口失败", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                        Text(browserListError)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                } else if model.browserWindows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("没有找到浏览器窗口")
                            .font(.system(size: 14, weight: .medium))
                        Text("请先打开浏览器窗口，然后点右上角刷新。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                } else {
                    Picker("窗口", selection: $model.selectedBrowserWindowID) {
                        ForEach(model.browserWindows) { window in
                            Text("\(window.applicationName) · \(window.displayTitle)")
                                .tag(Optional(window.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    if let note = model.browserSelectionNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    } else {
                        Text("原生像素优先，最高约 4K；成片只包含这个窗口。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(cardBackground)
        } else {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "display")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 66, height: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text("当前主屏幕")
                        .font(.system(size: 15, weight: .semibold))
                    Text("保留原生像素，最高约 4K 清晰度")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Snap Recorder 的窗口和录制控制条不会进入成片")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.green)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 118)
            .background(cardBackground)
        }
    }

    private var exportingView: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            ProgressView()
                .controlSize(.large)
                .padding(.bottom, 18)
            Text(model.phase == .preparingExport ? "正在整理录制…" : "正在生成高清视频…")
                .font(.system(size: 21, weight: .semibold))
            Text("完成后会自动保存到“下载”")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 7)
            Spacer()
        }
    }

    private var exportChoiceView: some View {
        VStack(spacing: 0) {
            header
            Spacer()

            Text("选择要保存的文件")
                .font(.system(size: 22, weight: .semibold))
            Text("可以选一种，也可以两种都选")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(spacing: 11) {
                Button {
                    model.toggleVoiceExportMode(.combined)
                } label: {
                    exportChoiceLabel(
                        title: "完整视频",
                        detail: model.activeCapturesSystemAudio
                            ? "画面、电脑声音和人声合成 1 个 MP4"
                            : "画面和人声合成 1 个 MP4",
                        icon: "rectangle.stack.badge.play.fill",
                        isSelected: model.selectedVoiceExportModes.contains(.combined)
                    )
                }
                .buttonStyle(
                    SnapExportChoiceButtonStyle(
                        isSelected: model.selectedVoiceExportModes.contains(.combined)
                    )
                )

                Button {
                    model.toggleVoiceExportMode(.separate)
                } label: {
                    exportChoiceLabel(
                        title: "视频和人声分轨",
                        detail: model.activeCapturesSystemAudio
                            ? "视频保留电脑声音，另存清晰人声 M4A"
                            : "无声视频 MP4 + 清晰人声 M4A",
                        icon: "square.split.2x1.fill",
                        isSelected: model.selectedVoiceExportModes.contains(.separate)
                    )
                }
                .buttonStyle(
                    SnapExportChoiceButtonStyle(
                        isSelected: model.selectedVoiceExportModes.contains(.separate)
                    )
                )
            }
            .padding(.top, 20)

            Button {
                model.exportVoiceRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.fill")
                    Text(model.voiceExportButtonTitle)
                }
            }
            .buttonStyle(SnapPrimaryButtonStyle())
            .disabled(model.selectedVoiceExportModes.isEmpty)
            .padding(.top, 15)

            if let errorMessage = model.errorMessage {
                VStack(spacing: 4) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    if !model.recoveryURLs.isEmpty {
                        Button("查看恢复文件") {
                            model.revealRecoveryFiles()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
            } else {
                Text("保存到“下载”，视频画质保持不变")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 11)
            }

            Spacer()
        }
    }

    private func exportChoiceLabel(
        title: String,
        detail: String,
        icon: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .opacity(0.72)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? .green : .white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.horizontal, 15)
    }

    private var finishedView: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(.green)
                .padding(.bottom, 15)
            Text(
                model.lastOutputURLs.count == 1
                    ? "录屏已保存"
                    : "\(model.lastOutputURLs.count) 个文件已保存"
            )
                .font(.system(size: 22, weight: .semibold))
            VStack(spacing: 3) {
                ForEach(model.lastOutputURLs, id: \.path) { url in
                    Text(url.lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 7)

            if let completionNote = model.completionNote {
                Text(completionNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }

            HStack(spacing: 12) {
                Button("在访达中显示") {
                    model.revealLastRecording()
                }
                .buttonStyle(SnapSecondaryButtonStyle())

                Button("再录一个") {
                    model.recordAgain()
                }
                .buttonStyle(SnapPrimaryButtonStyle())
            }
            .padding(.top, 24)
            Spacer()
        }
    }

    private var failedView: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.bottom, 15)
            Text(model.hasRetryableSave ? "录屏还在，保存未完成" : "这次没有完成")
                .font(.system(size: 22, weight: .semibold))
            Text(model.errorMessage ?? "发生了未知错误，请再试一次。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
                .padding(.top, 8)
            VStack(spacing: 9) {
                Button(model.hasRetryableSave ? "重试保存" : "返回") {
                    if model.hasRetryableSave {
                        model.retrySavingRecording()
                    } else {
                        model.recordAgain()
                    }
                }
                .buttonStyle(SnapPrimaryButtonStyle())
                .frame(width: 190)

                if !model.recoveryURLs.isEmpty {
                    Button("在访达中查看恢复文件") {
                        model.revealRecoveryFiles()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 23)
            Spacer()
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            }
    }
}

struct CountdownView: View {
    let number: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 42, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                }
            Text("\(number)")
                .font(.system(size: 76, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(7)
        .preferredColorScheme(.dark)
    }
}

struct RecordingHUDView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(model.phase == .paused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .shadow(color: (model.phase == .paused ? Color.orange : Color.red).opacity(0.65), radius: 6)

            Text(model.phase == .paused ? "已暂停" : model.elapsedText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(minWidth: 58, alignment: .leading)

            Divider()
                .frame(height: 20)
                .overlay(Color.white.opacity(0.15))

            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.phase == .paused ? "play.fill" : "pause.fill")
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.plain)
            .help(model.phase == .paused ? "继续" : "暂停")

            Button {
                model.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
            .help("结束录制")
        }
        .padding(.horizontal, 17)
        .frame(width: 274, height: 54)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
        .preferredColorScheme(.dark)
    }
}

private struct SnapPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.91, green: 0.25, blue: 0.43), .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.35)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct SnapSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 42)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.12))
            }
    }
}

private struct SnapExportChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.88, green: 0.22, blue: 0.41).opacity(0.72),
                                        Color.purple.opacity(0.72)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            : AnyShapeStyle(Color.white.opacity(0.11))
                    )
                    .opacity(configuration.isPressed ? 0.78 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected
                                    ? Color.white.opacity(0.18)
                                    : Color.white.opacity(0.1),
                                lineWidth: 1
                            )
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.988 : 1)
    }
}
