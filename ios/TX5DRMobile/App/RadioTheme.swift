import SwiftUI

enum RadioPalette {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.075)
    static let panel = Color(red: 0.065, green: 0.09, blue: 0.115)
    static let panelRaised = Color(red: 0.085, green: 0.115, blue: 0.145)
    static let accent = Color(red: 0.16, green: 0.82, blue: 0.72)
    static let cyan = Color(red: 0.18, green: 0.7, blue: 0.95)
    static let warning = Color(red: 1, green: 0.68, blue: 0.18)
    static let transmit = Color(red: 1, green: 0.24, blue: 0.26)
    static let muted = Color.white.opacity(0.58)
}

struct RadioPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(RadioPalette.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.055))
            }
    }
}
struct RadioActionButtonStyle: ButtonStyle {
    var tint: Color = RadioPalette.accent
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.82) : Color.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(
                prominent ? tint.opacity(configuration.isPressed ? 0.7 : 1) : tint.opacity(configuration.isPressed ? 0.28 : 0.14),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(tint.opacity(0.32))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
