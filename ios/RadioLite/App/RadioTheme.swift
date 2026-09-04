import SwiftUI

enum RadioPalette {
    static let background = TX.bg
    static let panel = TX.card
    static let panelRaised = TX.raised
    static let accent = TX.teal
    static let cyan = TX.teal
    static let warning = TX.amber
    static let transmit = TX.txRed
    static let muted = TX.text3
}

struct RadioPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(TX.pagePad)
            .background(TX.card, in: RoundedRectangle(cornerRadius: TX.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TX.cardRadius, style: .continuous)
                    .strokeBorder(TX.divider)
            }
    }
}
struct RadioActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = TX.teal
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TX.ui(15, .semibold))
            .foregroundStyle(
                isEnabled
                    ? (prominent ? TX.bg : TX.text1)
                    : TX.text3
            )
            .padding(.horizontal, 16)
            .frame(minHeight: TX.hitMin)
            .background(
                isEnabled
                    ? (prominent ? tint.opacity(configuration.isPressed ? 0.7 : 1) : tint.opacity(configuration.isPressed ? 0.28 : 0.14))
                    : TX.stroke,
                in: RoundedRectangle(cornerRadius: TX.cardRadius, style: .continuous)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: TX.cardRadius, style: .continuous)
                        .strokeBorder(tint.opacity(0.32))
                }
            }
            .saturation(isEnabled ? 1 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
