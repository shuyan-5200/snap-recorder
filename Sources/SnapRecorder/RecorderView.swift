import AppKit
import SwiftUI

/// 主面板：一块铝制操作面板。铭牌、来源旋钮、四路通道、最底部一颗橙色录制键；
/// 左侧人像、右侧导出均为同窗抽屉。视觉按“器物”规范，功能与交互保持原样。
struct RecorderView: View {
    @ObservedObject var model: AppModel
    @State private var showsCameraOptions = false
    @State private var showsExportDrawer = false
    @State private var drawerSide: RecorderDrawerSide = .left
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let drawerWidth = InstrumentDrawerMetrics.width + 2 * InstrumentDrawerMetrics.inset
    private static let sourceSelectorWidth: CGFloat = 158
    private static let sourceGap: CGFloat = 16
    private static let displayThumbnailHeight: CGFloat = 196
    private static let sourcePaneWidth: CGFloat = 560 - 48 - sourceSelectorWidth - sourceGap

    // The native full-size title bar already contributes the 44pt drag area.
    // One footprint for every mode and both drawers, below the native title bar.
    private static let panelHeight = InstrumentDrawerMetrics.height + 2 * InstrumentDrawerMetrics.inset

    var body: some View {
        ZStack {
            BrushedAluminum()
                .ignoresSafeArea()

            GeometryReader { geometry in
                // AppKit animates the actual window width. Deriving the reveal
                // from that width keeps the drawer and window in lockstep, and
                // avoids SwiftUI's minimum-size constraints snapping it open.
                let reveal = min(1, max(0, (geometry.size.width - 560) / Self.drawerWidth))
                HStack(alignment: .top, spacing: 0) {
                    if drawerSide == .left {
                        CameraOptionsView(settings: $model.cameraSettings) {
                            setCameraOptionsVisible(false)
                        }
                        .padding(InstrumentDrawerMetrics.inset)
                        .opacity(reveal)
                        .offset(x: (1 - reveal) * 12)
                        .frame(width: Self.drawerWidth, alignment: .trailing)
                        .allowsHitTesting(showsCameraOptions)
                        .disabled(!showsCameraOptions)
                        .accessibilityHidden(!showsCameraOptions)
                        .frame(height: windowHeight, alignment: .center)
                        .overlay(alignment: .trailing) { drawerSeparator.opacity(reveal) }
                    }

                    content
                        .padding(.top, 5)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)
                        .frame(width: 560, height: windowHeight)
                        .disabled(showsExportDrawer)

                    if drawerSide == .right {
                        exportDrawer
                            .padding(InstrumentDrawerMetrics.inset)
                            .opacity(reveal)
                            .offset(x: -(1 - reveal) * 12)
                            .frame(width: Self.drawerWidth, alignment: .leading)
                            .allowsHitTesting(showsExportDrawer)
                            .disabled(!showsExportDrawer)
                            .accessibilityHidden(!showsExportDrawer)
                            .frame(height: windowHeight, alignment: .center)
                        .overlay(alignment: .leading) { drawerSeparator.opacity(reveal) }
                    }
                }
                .frame(width: 560 + Self.drawerWidth, height: windowHeight, alignment: drawerSide == .left ? .topTrailing : .topLeading)
                .frame(width: geometry.size.width, height: windowHeight, alignment: drawerSide == .left ? .topTrailing : .topLeading)
                .clipped()
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity)
        .frame(height: windowHeight)
        .preferredColorScheme(.light)
        .onAppear {
            if isCameraDrawerPreview {
                setCameraOptionsVisible(true)
            }
            if model.permissionGranted {
                Task { await model.refreshWindows() }
                model.captureModeDidChange(model.mode)
            }
        }
        .onChange(of: model.mode) { _, newValue in
            model.captureModeDidChange(newValue)
            if newValue == .window, model.permissionGranted {
                Task { await model.refreshWindows() }
            }
        }
        .onChange(of: model.cameraSettings) { _, _ in model.updateCameraPreview() }
        .onChange(of: model.capturesCamera) { _, enabled in
            setCameraOptionsVisible(enabled && model.phase == .idle)
        }
        .onChange(of: model.phase, initial: true) { _, phase in
            synchronizeDrawers(for: phase)
            model.updateDisplayPreview()
        }
    }

    private var drawerSeparator: some View {
        Rectangle()
            .fill(Instrument.groove)
            .frame(width: 1)
            .padding(.vertical, InstrumentDrawerMetrics.inset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func setCameraOptionsVisible(_ visible: Bool) {
        guard showsCameraOptions != visible else { return }
        if visible { drawerSide = .left }
        model.prepareDrawerVisibilityChange(
            width: visible ? 560 + Self.drawerWidth : 560,
            side: .left,
            animated: !reduceMotion
        )
        showsCameraOptions = visible
    }

    private func synchronizeDrawers(for phase: RecordingPhase) {
        let opensExport: Bool
        switch phase {
        case .preparingExport, .choosingExport, .exporting, .finished: opensExport = true
        default: opensExport = false
        }
        if opensExport {
            guard !showsExportDrawer else { return }
            showsCameraOptions = false
            drawerSide = .right
            showsExportDrawer = true
            model.prepareDrawerVisibilityChange(width: 560 + Self.drawerWidth, side: .right, animated: !reduceMotion)
        } else if showsExportDrawer {
            showsExportDrawer = false
            model.prepareDrawerVisibilityChange(width: 560, side: .right, animated: !reduceMotion)
        } else if phase != .idle {
            setCameraOptionsVisible(false)
        }
    }

    /// Layout checks can inspect the drawer without opening the camera.
    private var isCameraDrawerPreview: Bool {
        CommandLine.arguments.contains("--preview-camera-drawer")
    }

    private var windowHeight: CGFloat {
        Self.panelHeight
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .countdown, .recording, .paused, .preparingExport, .exporting, .choosingExport, .finished:
            if model.permissionGranted {
                setupView
            } else {
                permissionView
            }
        case .failed:
            failedView
        }
    }

    // MARK: - 权限

    private var permissionView: some View {
        VStack(spacing: 0) {
            Nameplate()
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Instrument.ink2)
                    .padding(.bottom, 2)

                Text("开始你的第一次录屏")
                    .font(Instrument.text(20, weight: .semibold))
                    .foregroundStyle(Instrument.graphite)

                Text("需要 macOS 的屏幕录制权限。视频只在这台 Mac 上处理，录完选择画质并保存到“下载”。")
                    .font(Instrument.text(13))
                    .foregroundStyle(Instrument.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
                    .lineSpacing(4)

                if model.hasRequestedPermission {
                    Button("打开系统设置") {
                        model.openScreenRecordingSettings()
                    }
                    .buttonStyle(KeyButtonStyle(kind: .dark))
                    .frame(width: 210)
                    .padding(.top, 4)

                    VStack(spacing: 6) {
                        Button("我已开启，重新检查") {
                            model.recheckPermission()
                        }
                        .buttonStyle(LinkTextButtonStyle())

                        Text("在系统设置中开启后，请完全退出并重新打开当前这份 Snap Recorder；不需要反复点击授权。")
                            .font(Instrument.text(11))
                            .foregroundStyle(Instrument.engrave)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                } else {
                    Button("允许屏幕录制") {
                        model.requestPermission()
                    }
                    .buttonStyle(KeyButtonStyle(kind: .dark))
                    .frame(width: 210)
                    .padding(.top, 4)
                }
            }

            Spacer()
            Text("视频只保存在本机，录制浮窗不会进入成片")
                .font(Instrument.text(11))
                .foregroundStyle(Instrument.engrave)
        }
    }

    // MARK: - 录前设置

    private var setupView: some View {
        VStack(spacing: 0) {
            Nameplate()

            panelModule("来源") {
                HStack(alignment: .top, spacing: Self.sourceGap) {
                    sourceControls
                    sourceDetail
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            // The source group must not recenter when its detail pane changes.
            // Keep the title, dial and mode stops anchored to the same top edge.
            .fixedSize(horizontal: false, vertical: model.mode != .window)
            .frame(maxHeight: .infinity, alignment: .top)

            Groove()

            panelModule("声音与画面") {
                channels
            }

            Groove()

            Button {
                model.startRecording()
            } label: {
                RecordKeyLabel()
            }
            .buttonStyle(KeyButtonStyle(kind: .record))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canStartRecording)
            .accessibilityLabel("开始录制")
            .padding(.top, 20)
            .padding(.bottom, 2)
        }
        .disabled(model.phase != .idle)
    }

    private func panelModule<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            EngravedLabel(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    // MARK: 来源旋钮

    private var sourceControls: some View {
        VStack(alignment: .sourceModeTrailing, spacing: 0) {
            sourceSelector
            if model.mode == .display, model.availableDisplays.count > 1 {
                let thumbnailSize = ScreenPresentation.thumbnailSize(source: displayThumbnailSourceSize,
                    within: CGSize(width: Self.sourcePaneWidth, height: Self.displayThumbnailHeight))
                // Thumbnail begins 28pt below the dial's top edge. Keep the
                // number keys centered beside it without covering mode stops.
                let railHeight = min(Self.displayThumbnailHeight - 38,
                    CGFloat(model.availableDisplays.count * 40 + 6))
                let topGap = max(6, 28 + (thumbnailSize.height - railHeight) / 2 - 60)
                displayNumberRail
                    .frame(width: 40, height: railHeight)
                    .alignmentGuide(.sourceModeTrailing) { $0[.trailing] - 6 }
                    .padding(.top, topGap)
            }
        }
        .frame(width: Self.sourceSelectorWidth, alignment: .topLeading)
    }

    private var sourceSelector: some View {
        HStack(spacing: 10) {
            SourceKnob(angle: knobAngle)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(CaptureMode.allCases) { mode in
                    sourceStop(mode)
                }
            }
            .alignmentGuide(.sourceModeTrailing) { $0[.trailing] }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("录制来源")
            .onMoveCommand { direction in
                let modes = CaptureMode.allCases
                guard let index = modes.firstIndex(of: model.mode) else { return }
                switch direction {
                case .up, .left:
                    if index > 0 { model.mode = modes[index - 1] }
                case .down, .right:
                    if index < modes.count - 1 { model.mode = modes[index + 1] }
                @unknown default:
                    break
                }
            }
        }
        .frame(width: Self.sourceSelectorWidth, height: 60, alignment: .leading)
    }

    private var knobAngle: Angle {
        switch model.mode {
        case .window: .degrees(-29)
        case .display: .degrees(0)
        case .region: .degrees(29)
        }
    }

    private func sourceStop(_ mode: CaptureMode) -> some View {
        let selected = model.mode == mode
        return Button {
            model.mode = mode
        } label: {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(Instrument.groove)
                    .frame(width: 7, height: 1)
                LED(state: selected ? .lit : .off)
                Text(mode.title)
                    .font(Instrument.text(12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Instrument.buttonText : Instrument.engrave)
                    .padding(.leading, 2)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityValue(selected ? "已选" : "未选")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var sourceDetail: some View {
        switch model.mode {
        case .window:
            windowSourcePane
        case .display:
            displaySourcePane
        case .region:
            regionSourcePane
        }
    }

    private var windowSourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                paneTitle("选择一个窗口")
                Spacer()
                Button {
                    Task { await model.refreshWindows() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(KeyButtonStyle(kind: .icon))
                .help("刷新窗口")
                .accessibilityLabel("刷新窗口")
            }
            .padding(.bottom, 6)

            if model.isLoadingWindows {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取可录制窗口…")
                        .font(Instrument.text(11))
                        .foregroundStyle(Instrument.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else if let windowListError = model.windowListError {
                VStack(alignment: .leading, spacing: 4) {
                    Label("读取窗口失败", systemImage: "exclamationmark.triangle")
                        .font(Instrument.text(12, weight: .semibold))
                        .foregroundStyle(Instrument.warn)
                    Text(windowListError)
                        .font(Instrument.text(11))
                        .foregroundStyle(Instrument.ink2)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else if model.availableWindows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("没有找到可录制窗口")
                        .font(Instrument.text(12, weight: .semibold))
                        .foregroundStyle(Instrument.graphite)
                    Text("请先打开一个应用窗口，然后点右上角刷新。")
                        .font(Instrument.text(11))
                        .foregroundStyle(Instrument.ink2)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                windowList

                if let note = model.windowSelectionNote {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(Instrument.text(10.5))
                        .foregroundStyle(Instrument.warn)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var windowList: some View {
        let outline = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(model.availableWindows) { window in
                        windowListRow(window)
                            .id(window.id)
                    }
                }
                .padding(6)
            }
            .frame(minHeight: 96, maxHeight: .infinity)
            .background { outline.fill(Instrument.aluLo.opacity(0.22)) }
            .clipShape(outline)
            .overlay { outline.strokeBorder(Instrument.groove, lineWidth: 1).allowsHitTesting(false) }
            .accessibilityLabel("可录制窗口")
            .onAppear {
                if let selected = model.selectedWindowID { proxy.scrollTo(selected, anchor: .center) }
            }
            .onChange(of: model.availableWindows.map(\.id)) { _, _ in
                if let selected = model.selectedWindowID { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    private func windowListRow(_ window: CaptureWindowInfo) -> some View {
        let selected = model.selectedWindowID == window.id
        let outline = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Button {
            model.selectWindow(window.id)
        } label: {
            HStack(spacing: 8) {
                LED(state: selected ? .lit : .off, size: 5)
                Text("\(window.applicationName) · \(window.displayTitle)")
                    .font(Instrument.text(11.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Instrument.buttonText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { outline.fill(selected ? Instrument.aluHi.opacity(0.85) : .clear) }
            .overlay { outline.strokeBorder(selected ? Instrument.buttonText.opacity(0.45) : .clear, lineWidth: 1) }
            .contentShape(outline)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("窗口：\(window.applicationName) · \(window.displayTitle)")
        .accessibilityValue(selected ? "已选" : "未选")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var displaySourcePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    paneTitle(model.selectedDisplay?.name ?? "选择一个屏幕")
                        .lineLimit(1)
                        .help(model.selectedDisplay?.name ?? "选择一个屏幕")
                    if let display = model.selectedDisplay {
                        Text("\(Int(display.pixelSize.width)) × \(Int(display.pixelSize.height))")
                            .font(Instrument.mono(9.5))
                            .foregroundStyle(Instrument.engrave)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 0)
                Button { Task { await model.refreshDisplays(userInitiated: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(KeyButtonStyle(kind: .icon))
                .frame(minWidth: 40, minHeight: 40)
                .disabled(model.isLoadingDisplays)
                .accessibilityLabel("刷新屏幕")
            }

            displayThumbnail.frame(height: Self.displayThumbnailHeight)

            if let message = model.displayListError ?? model.displayPreviewError {
                Text(message)
                    .font(Instrument.text(10.5))
                    .foregroundStyle(model.displayListError != nil ? Instrument.warn : Instrument.engrave)
                    .lineLimit(1)
            }
        }
        // Lift one text row without moving the shared source-selector anchor.
        // The reclaimed title/readout space goes to the thumbnail itself.
        .padding(.top, -20)
    }

    private var displayThumbnailSourceSize: CGSize {
        model.displayThumbnail.map { CGSize(width: $0.width, height: $0.height) }
            ?? model.selectedDisplay?.pixelSize ?? CGSize(width: 16, height: 9)
    }

    private var displayNumberRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(model.availableDisplays.enumerated()), id: \.element.id) { index, display in
                    Button { model.selectDisplay(display.id) } label: {
                        Text("\(index + 1)").font(Instrument.mono(13))
                    }
                    .buttonStyle(KeyButtonStyle(kind: .displayNumber, isLatched: model.selectedDisplayID == display.id))
                    .help("\(display.name) · \(display.detail)")
                    .accessibilityLabel("屏幕 \(index + 1)：\(display.name)")
                    .accessibilityValue(model.selectedDisplayID == display.id ? "已选" : "未选")
                    .accessibilityAddTraits(model.selectedDisplayID == display.id ? .isSelected : [])
                }
            }
            .padding(.vertical, 3)
        }
    }

    private var displayThumbnail: some View {
        GeometryReader { geometry in
            let size = ScreenPresentation.thumbnailSize(source: displayThumbnailSourceSize, within: geometry.size)
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            ZStack {
                if let image = model.displayThumbnail {
                    Image(decorative: image, scale: 1)
                        .resizable()
                } else {
                    shape.fill(Instrument.aluLo.opacity(0.3))
                    if model.isLoadingDisplayThumbnail || model.isLoadingDisplays {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "display")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(Instrument.engrave)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.black.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("所选屏幕缩略图")
    }

    private var regionSourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                paneTitle("画面比例")
                Spacer(minLength: 6)
            }
            .padding(.bottom, 8)

            HStack(spacing: 4) {
                ForEach(CaptureAspectRatio.allCases) { aspectRatio in
                    let selected = model.selectedRegionAspectRatio == aspectRatio
                    Button {
                        model.selectRegionAspectRatio(aspectRatio)
                    } label: {
                        VStack(spacing: 5) {
                            RatioGlyph(aspectRatio: aspectRatio)
                            Text(aspectRatio.title)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KeyButtonStyle(kind: .ratio, isLatched: selected, fillsWidth: true))
                    .accessibilityLabel(aspectRatio.title)
                    .accessibilityValue(selected ? "已选" : "未选")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.bottom, 2)

            VStack(spacing: 0) {
                captureCornerStyleOptionRow
                RowSeparator()
                vignetteOptionRow
                RowSeparator()
                focusMaskOptionRow
            }
            .padding(.top, 10)
        }
    }

    private func optionRow<Controls: View>(
        title: String,
        help: String,
        isEnabled: Bool = true,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Instrument.text(12, weight: .semibold))
                .foregroundStyle(Instrument.graphite)
                .opacity(isEnabled ? 1 : 0.5)
            Spacer(minLength: 6)
            controls()
        }
        .frame(minHeight: 44)
        .help(help)
    }

    private var captureCornerStyleOptionRow: some View {
        optionRow(title: "录制框边角", help: "默认圆角，也可保留方角") {
            InterlockKeys(
                accessibilityTitle: "录制框边角",
                options: FocusMaskCornerStyle.allCases,
                selection: model.captureRegionCornerStyle,
                title: \.title,
                mini: true
            ) { model.setCaptureRegionCornerStyle($0) }
        }
    }

    private var vignetteOptionRow: some View {
        let isEnabled = model.captureRegionCornerStyle == .rounded
        return optionRow(
            title: "柔和圆角暗角",
            help: "四角轻微渐隐，让画面更柔和",
            isEnabled: isEnabled
        ) {
            SlideSwitch("柔和圆角暗角", isOn: $model.appliesSoftCornerVignette)
                .disabled(!isEnabled)
        }
    }

    private var focusMaskOptionRow: some View {
        let isAvailable = model.selectedRegionAspectRatio != .custom
        return optionRow(
            title: "聚焦蒙版",
            help: isAvailable ? "框内原色，框外单色并压暗 50%" : "选择固定比例后可用",
            isEnabled: isAvailable
        ) {
            if model.isFocusMaskEnabled {
                InterlockKeys(
                    accessibilityTitle: "蒙版边角",
                    options: FocusMaskCornerStyle.allCases,
                    selection: model.focusMaskCornerStyle,
                    title: \.title,
                    mini: true
                ) { model.setFocusMaskCornerStyle($0) }
            }

            SlideSwitch(
                "聚焦蒙版",
                isOn: Binding(
                    get: { model.isFocusMaskEnabled },
                    set: { model.setFocusMaskEnabled($0) }
                )
            )
            .disabled(!isAvailable)
        }
    }

    // MARK: 四路通道

    // Compact equal-height channels; permission recovery grows the whole row.
    private var channelHeight: CGFloat {
        model.cameraMessage != nil
            || (model.microphoneMessage != nil && model.microphoneFeatureAvailable) ? 128 : 100
    }

    private var channels: some View {
        HStack(alignment: .top, spacing: 8) {
            cameraChannel

            channelStrip(
                title: "电脑声音", detail: ChannelDescriptions.systemAudio,
                isOn: model.capturesSystemAudio
            ) {
                SlideSwitch("电脑声音", isOn: $model.capturesSystemAudio,
                    indicatorSpacing: Instrument.channelIndicatorSpacing)
            }

            channelStrip(
                title: "人声（麦克风）",
                detail: microphoneSubtitle,
                detailHelp: model.microphoneMessage,
                isOn: model.capturesMicrophone,
                isBusy: model.isRequestingMicrophonePermission,
                isWarning: model.microphoneMessage != nil,
                showsAccessory: model.microphoneMessage != nil && model.microphoneFeatureAvailable
            ) {
                if model.isRequestingMicrophonePermission {
                    ProgressView().controlSize(.small)
                } else {
                    SlideSwitch(
                        "人声（麦克风）",
                        isOn: Binding(
                            get: { model.capturesMicrophone },
                            set: { model.setMicrophoneCaptureEnabled($0) }
                        ),
                        indicatorSpacing: Instrument.channelIndicatorSpacing
                    )
                    .disabled(!model.microphoneFeatureAvailable)
                }
            } accessory: {
                if model.microphoneMessage != nil, model.microphoneFeatureAvailable {
                    Button("打开设置") {
                        model.openMicrophoneSettings()
                    }
                    .buttonStyle(KeyButtonStyle(kind: .small))
                }
            }

            channelStrip(
                title: "录制鼠标",
                detail: model.capturesMouseEffects ? ChannelDescriptions.mouseOn : ChannelDescriptions.mouseOff,
                isOn: model.capturesMouseEffects
            ) {
                SlideSwitch("录制鼠标", isOn: $model.capturesMouseEffects,
                    indicatorSpacing: Instrument.channelIndicatorSpacing)
            }

        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cameraChannel: some View {
        channelStrip(
            title: "摄像头",
            detail: cameraSubtitle,
            detailHelp: model.cameraMessage,
            isOn: model.capturesCamera,
            isBusy: model.isPreparingCamera,
            isWarning: model.cameraMessage != nil,
            showsAccessory: model.cameraMessage != nil
        ) {
            SlideSwitch(
                "摄像头",
                isOn: Binding(
                    get: { model.capturesCamera },
                    set: { model.setCameraCaptureEnabled($0) }
                ),
                isBusy: model.isPreparingCamera,
                indicatorSpacing: Instrument.channelIndicatorSpacing
            )
            if model.isPreparingCamera {
                ProgressView().controlSize(.mini)
            }
        } accessory: {
            if model.cameraMessage != nil {
                Button("设置") { model.openCameraSettings() }
                    .buttonStyle(KeyButtonStyle(kind: .small))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if model.capturesCamera, model.phase == .idle {
                setCameraOptionsVisible(true)
            }
        }
        .help(model.capturesCamera ? "点击摄像头卡片调整人像样式" : "开启后自动展开人像样式")
    }

    private func channelStrip<Controls: View, Accessory: View>(
        title: String,
        detail: String,
        detailHelp: String? = nil,
        isOn: Bool,
        isBusy: Bool = false,
        isWarning: Bool = false,
        showsAccessory: Bool = false,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(isBusy ? "准备中" : isWarning ? "需设置" : isOn ? "已开启" : "已关闭")
                    .font(Instrument.text(9, weight: .medium))
                    .foregroundStyle(isWarning ? Instrument.warn : Instrument.engrave)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                controls()
            }
            .frame(height: 22)

            Spacer(minLength: 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Instrument.text(12, weight: .semibold))
                    .foregroundStyle(Instrument.graphite)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(detail)
                    .font(Instrument.text(9.5))
                    .foregroundStyle(isWarning ? Instrument.warn : Instrument.engrave)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(detailHelp ?? detail)
            }

            // Reserve the recovery row across all four cards so their captions
            // retain the same baseline, even when only one needs Settings.
            if channelHeight > 100 {
                HStack(spacing: 6) {
                    if showsAccessory { accessory() }
                    Spacer(minLength: 0)
                }
                .frame(height: 24)
                .padding(.top, 6)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 7, trailing: 10))
        .frame(maxWidth: .infinity)
        .frame(height: channelHeight, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(Color(hex: 0xCECCC7))
                InnerShadow(shape: shape, color: .black.opacity(0.12), radius: 1, y: 1)
                shape.strokeBorder(
                    isWarning ? Instrument.warn : Instrument.groove,
                    lineWidth: 1
                )
            }
        }
    }

    private var microphoneSubtitle: String {
        if model.microphoneMessage != nil { return ChannelDescriptions.microphoneError }
        if !model.microphoneFeatureAvailable { return ChannelDescriptions.microphoneUnavailable }
        if model.isRequestingMicrophonePermission { return ChannelDescriptions.microphonePreparing }
        return model.capturesMicrophone ? ChannelDescriptions.microphoneOn : ChannelDescriptions.microphoneOff
    }

    private var cameraSubtitle: String {
        if model.cameraMessage != nil { return ChannelDescriptions.cameraError }
        if model.isPreparingCamera { return ChannelDescriptions.cameraPreparing }
        return model.capturesCamera ? ChannelDescriptions.cameraOn : ChannelDescriptions.cameraOff
    }

    private func paneTitle(_ text: String) -> some View {
        Text(text)
            .font(Instrument.text(12, weight: .semibold))
            .foregroundStyle(Instrument.graphite)
            .frame(minHeight: 18)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Instrument.text(10.5))
            .foregroundStyle(Instrument.engrave)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 导出中

    private var exportDrawer: some View {
        InstrumentDrawer(
            title: "录制",
            durationText: exportDurationText,
            canDismiss: model.isExportWorkspace,
            showsFooter: model.phase != .preparingExport,
            closeLabel: "关闭导出录制",
            dismiss: { model.closeExportDrawer() }
        ) {
            EmptyView()
        } content: {
            if model.phase == .preparingExport || model.phase == .exporting {
                exportingView
            } else {
                exportChoiceView
            }
        } footer: {
            if model.phase == .exporting {
                Button(model.isCancellingExport ? "正在取消…" : "取消导出") {
                    model.cancelExport()
                }
                .buttonStyle(KeyButtonStyle(fillsWidth: true))
                .disabled(model.isCancellingExport)
            } else {
                exportFooter
            }
        }
    }

    private var exportingView: some View {
        VStack(spacing: 0) {
            ChaserLights()
                .padding(.bottom, 18)
            Text(model.phase == .preparingExport ? "正在整理录制…" : "正在导出…")
                .font(Instrument.text(16, weight: .semibold))
                .foregroundStyle(Instrument.graphite)
        }
        .padding(.vertical, 14)
    }

    // MARK: - 命名与导出

    private var exportDurationText: String {
        model.exportInfo.map { TimeFormatting.recordingDuration($0.duration) } ?? model.elapsedText
    }

    private var exportChoiceView: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                InstrumentDrawerField(title: "导出内容") {
                    HStack(spacing: 6) {
                        ForEach(RecordingTrack.allCases) { track in
                            let available = model.exportInfo?.availableTracks.contains(track) == true
                            LatchKey(
                                title: track.title,
                                isOn: model.selectedExportTracks.contains(track),
                                fillsWidth: true
                            ) {
                                model.toggleExportTrack(track)
                            }
                            .disabled(!available)
                            .help(available ? track.title : "未录制" + track.title)
                        }
                    }
                }

                InstrumentDrawerDivider()

                InstrumentDrawerField(title: "输出方式") {
                    InterlockKeys(
                        accessibilityTitle: "输出方式",
                        options: ExportArrangement.allCases,
                        selection: model.selectedExportArrangement,
                        title: \.title,
                        fills: true
                    ) { arrangement in
                        model.selectedExportArrangement = arrangement
                        model.errorMessage = nil
                    }
                }

                if model.exportSelection.includesVideo {
                    InstrumentDrawerDivider()
                    InstrumentDrawerField(title: "视频大小") {
                        VStack(spacing: 8) {
                            videoSizeControls
                            videoExportReadout
                        }
                    }
                }

                InstrumentDrawerDivider()

                HStack(alignment: .top, spacing: 8) {
                    InstrumentDrawerField(title: "文件名") {
                        TextField("文件名", text: $model.exportName)
                            .grooveField(isInvalid: model.exportValidationMessage?.hasPrefix("文件名") == true)
                            .accessibilityLabel("文件名")
                            .help(model.exportName)
                            .frame(height: 40)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)

                    customVideoSizeField
                        .frame(minWidth: 0, maxWidth: .infinity)
                }

                if usesCustomVideoSize, !model.customSizeGuidance.isEmpty {
                    Text(model.customSizeGuidance)
                        .font(Instrument.text(10.5))
                        .foregroundStyle(Instrument.engrave)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }

            if let message = exportNotice {
                Text(message)
                    .font(Instrument.text(12))
                    .foregroundStyle(Instrument.warn)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(message)
            }
        }
    }

    private var exportNotice: String? {
        model.errorMessage ?? model.exportValidationMessage ?? model.completionNote
    }

    private var exportFooter: some View {
        HStack(spacing: 8) {
            Button {
                model.exportRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.exportButtonTitle)
                }
            }
            .buttonStyle(KeyButtonStyle(kind: .dark))
            .disabled(!model.canExport)
            .accessibilityLabel(model.exportButtonTitle)

            Button {
                model.restartRecording()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text("重新录制")
                }
            }
            .buttonStyle(KeyButtonStyle(kind: .secondaryAction))
            .help(model.hasUnfinishedSave ? "先确认放弃未保存的原片，再重新录制；原片可在废纸篓找回" : "保留已导出文件，再重新录制")
            .accessibilityLabel("重新录制")
        }
    }

    private var videoSizeControls: some View {
        FivePositionSlider(
            accessibilityTitle: "视频大小",
            options: RecordingQualityPreset.allCases,
            selection: model.selectedQualityPreset,
            title: \.title,
            help: { $0 == .tiny ? "适合随手记录，小字细节会减少" : $0.detail }
        ) { model.selectedQualityPreset = $0 }
    }

    @ViewBuilder
    private var videoExportReadout: some View {
        if !model.exportEstimate.isEmpty {
            Text(model.exportEstimate)
                .font(Instrument.mono(10))
                .monospacedDigit()
                .foregroundStyle(Instrument.readout)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .background { DisplayWindowBackground() }
                .help(model.exportEstimate)
        }
    }

    private var customVideoSizeField: some View {
        InstrumentDrawerField(title: "自定义上限（MB）") {
            TextField("MB", text: $model.customSizeMegabytes)
                .multilineTextAlignment(.trailing)
                .grooveField(
                    isInvalid: model.exportValidationMessage?.hasPrefix("视频上限") == true,
                    monospaced: true
                )
                .accessibilityLabel("自定义视频大小上限 MB")
                .disabled(!usesCustomVideoSize)
                .help(usesCustomVideoSize ? "\(model.customSizeGuidance)\n\(model.exportEstimate)" : "选择视频和自定义档后可设置每个视频的大小上限")
                .frame(height: 40)
        }
    }

    private var usesCustomVideoSize: Bool {
        model.exportSelection.includesVideo && model.selectedQualityPreset == .custom
    }

    // MARK: - 失败

    private var failedView: some View {
        VStack(spacing: 0) {
            Nameplate()
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(Instrument.warn)
                .padding(.bottom, 14)
            Text(model.hasRetryableSave ? "录屏还在，保存未完成" : "这次没有完成")
                .font(Instrument.text(20, weight: .semibold))
                .foregroundStyle(Instrument.graphite)
            Text(model.errorMessage ?? "发生了未知错误，请再试一次。")
                .font(Instrument.text(13))
                .foregroundStyle(Instrument.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
                .padding(.top, 8)
            VStack(spacing: 12) {
                Button(model.hasRetryableSave ? "重试保存" : "返回") {
                    if model.hasRetryableSave {
                        model.retrySavingRecording()
                    } else {
                        model.recordAgain()
                    }
                }
                .buttonStyle(KeyButtonStyle(kind: .dark))
                .frame(width: 190)

                if !model.recoveryURLs.isEmpty {
                    Button("在访达中查看恢复文件") {
                        model.revealRecoveryFiles()
                    }
                    .buttonStyle(KeyButtonStyle(kind: .small))
                }
            }
            .padding(.top, 22)
            Spacer()
        }
    }
}

/// 录制键的键面：左侧刻一枚石墨圆点作录制符号，右侧刻 ⌘R。
private struct RecordKeyLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(isEnabled ? Instrument.graphite : Instrument.disabled)
                    .frame(width: 10, height: 10)
                    .background { Circle().fill(Color.white.opacity(isEnabled ? 0.35 : 0)).offset(y: 1) }
                Text("开始录制")
            }
            HStack {
                Spacer()
                KeyCap(
                    text: "⌘R",
                    keepsOriginalTextSize: true,
                    color: isEnabled ? Instrument.graphite : Instrument.disabled,
                    border: Instrument.graphite.opacity(isEnabled ? 0.45 : 0.2)
                )
                .padding(.trailing, -4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 倒计时

/// 174 × 174 铝板，132 圆形表盘，一圈 60 格刻度；72 号点阵数字；暖白指针每秒扫一圈。
struct CountdownView: View {
    let number: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeps = false

    var body: some View {
        ZStack {
            AluminumPanelBackground(cornerRadius: 10, borderOpacity: 0.35)

            ZStack {
                let dial = Circle()
                dial
                    .fill(Instrument.window)
                    .overlay { InnerShadow(shape: dial, color: .black.opacity(0.7), radius: 3, y: 2) }
                    .background { dial.fill(Color.white.opacity(0.6)).offset(y: 1) }

                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    var ticks = Path()
                    for index in 0..<60 {
                        let angle = Double(index) * 6 * .pi / 180
                        let direction = CGPoint(x: sin(angle), y: -cos(angle))
                        ticks.move(to: CGPoint(x: center.x + direction.x * 52, y: center.y + direction.y * 52))
                        ticks.addLine(to: CGPoint(x: center.x + direction.x * 60, y: center.y + direction.y * 60))
                    }
                    context.stroke(ticks, with: .color(Instrument.readout.opacity(0.5)), lineWidth: 0.8)
                }

                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Instrument.readout)
                    .frame(width: 2, height: 58)
                    .shadow(color: Instrument.readout.opacity(0.4), radius: 2)
                    .frame(height: 116, alignment: .top)
                    .rotationEffect(.degrees(sweeps ? 360 : 0))

                DotMatrixText(text: "\(number)", size: 72, pitch: 3.6)
            }
            .frame(width: 132, height: 132)
        }
        .overlay(alignment: .topLeading) { Screw(size: 6).padding(8) }
        .overlay(alignment: .topTrailing) { Screw(size: 6).padding(8) }
        .overlay(alignment: .bottomLeading) { Screw(size: 6).padding(8) }
        .overlay(alignment: .bottomTrailing) { Screw(size: 6).padding(8) }
        .frame(width: 174, height: 174)
        .preferredColorScheme(.light)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1)) { sweeps = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("倒计时 \(number)")
    }
}

// MARK: - 录制控制条

/// 铝面板圆角 10；橙灯录制时常亮、暂停时 1.2 秒慢闪；显示窗 18 号点阵计时；暂停与结束为 30 × 30 实体键。
struct RecordingHUDView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let paused = model.phase == .paused
        HStack(spacing: 10) {
            RecordingLamp(isPaused: paused)

            ZStack {
                if paused {
                    Text("已暂停")
                        .font(Instrument.text(12, weight: .semibold))
                        .foregroundStyle(Instrument.readout)
                } else {
                    DotMatrixText(text: model.elapsedText, size: 18)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background { DisplayWindowBackground() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(paused ? "已暂停" : "已录制 \(model.elapsedText)")

            Button {
                model.togglePause()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(KeyButtonStyle(kind: .hud))
            .help(paused ? "继续" : "暂停")
            .accessibilityLabel(paused ? "继续" : "暂停")

            Button {
                model.stopRecording()
            } label: {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Instrument.graphite)
                    .frame(width: 9, height: 9)
            }
            .buttonStyle(KeyButtonStyle(kind: .hud))
            .help("结束录制（Esc）")
            .accessibilityLabel("结束录制")

            KeyCap(text: "esc")
                .accessibilityHidden(true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(width: 274, height: 54)
        .background { AluminumPanelBackground(cornerRadius: 10, borderOpacity: 0.35) }
        .preferredColorScheme(.light)
    }
}

/// 录制灯：信号橙，录制时常亮，暂停时 1.2 秒一次慢闪；减少动态效果时暂停改为常暗。
private struct RecordingLamp: View {
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isPaused, !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.6)) { context in
                    lamp(lit: Int(context.date.timeIntervalSinceReferenceDate / 0.6).isMultiple(of: 2))
                }
            } else {
                lamp(lit: !isPaused)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }

    private func lamp(lit: Bool) -> some View {
        ZStack {
            if lit {
                Circle()
                    .fill(Instrument.signal.opacity(0.5))
                    .frame(width: 16, height: 16)
                    .blur(radius: 3)
            }
            Circle()
                .fill(Instrument.ledRing)
                .frame(width: 12, height: 12)
            Circle()
                .fill(lit ? Instrument.signal : Color(hex: reduceMotion ? 0x8A4A2C : 0x5A3A2C))
                .frame(width: 8, height: 8)
        }
    }
}

private enum SourceModeTrailingAlignment: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[.trailing] }
}

private extension HorizontalAlignment {
    static let sourceModeTrailing = HorizontalAlignment(SourceModeTrailingAlignment.self)
}
