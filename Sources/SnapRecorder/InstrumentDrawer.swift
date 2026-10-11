import SwiftUI

/// Shared card, inset and action-area dimensions keep both drawers aligned.
enum InstrumentDrawerMetrics {
    static let width: CGFloat = 354
    static let height: CGFloat = 536
    static let inset: CGFloat = 12
    static let headerHeight: CGFloat = 62
    static let footerHeight = Instrument.actionHeight
}

/// A single language for both drawers: engraved title, then full-width controls.
struct InstrumentDrawerField<Content: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                EngravedLabel(title)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(Instrument.mono(10))
                        .foregroundStyle(Instrument.engrave)
                        .lineLimit(1)
                }
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct InstrumentDrawerDivider: View {
    var body: some View {
        Groove()
            .padding(.vertical, 2)
            .frame(maxHeight: .infinity)
    }
}

/// Both drawers have the same closed outline, header and footer boundaries.
struct InstrumentDrawer<Accessory: View, Content: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var durationText: String? = nil
    var canDismiss = true
    var showsCloseButton = true
    var showsFooter = true
    let closeLabel: String
    let dismiss: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let durationText {
                    HStack(spacing: 10) {
                        Text(title)
                            .font(Instrument.text(15, weight: .semibold))
                            .foregroundStyle(Instrument.graphite)
                        DotMatrixText(text: durationText, size: 17)
                            .padding(.horizontal, 9)
                            .frame(minWidth: 88, minHeight: 26)
                            .background { DisplayWindowBackground() }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("录制时长 \(durationText)")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(Instrument.text(15, weight: .semibold))
                            .foregroundStyle(Instrument.graphite)
                        if let subtitle {
                            Text(subtitle)
                                .font(Instrument.mono(10))
                                .foregroundStyle(Instrument.engrave)
                                .monospacedDigit()
                        }
                    }
                }
                Spacer(minLength: 0)
                accessory()
                if showsCloseButton {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(KeyButtonStyle(kind: .icon))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                    .accessibilityLabel(closeLabel)
                    .disabled(!canDismiss)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(height: InstrumentDrawerMetrics.headerHeight)
            .fixedSize(horizontal: false, vertical: true)

            Groove()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            if showsFooter {
                Groove()
                footer()
                    .frame(maxWidth: .infinity)
                    .frame(height: InstrumentDrawerMetrics.footerHeight, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: InstrumentDrawerMetrics.width, height: InstrumentDrawerMetrics.height)
        .background {
            AluminumPanelBackground(cornerRadius: 10)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        }
    }
}
