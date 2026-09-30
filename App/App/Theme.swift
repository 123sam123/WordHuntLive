import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let panel = Color(red: 0.086, green: 0.094, blue: 0.114)
    static let panelBorder = Color.white.opacity(0.07)
    static let tile = Color(red: 0.14, green: 0.15, blue: 0.18)
    static let tileText = Color(white: 0.94)
    static let secondaryText = Color(white: 0.55)
    /// The path colour — must pop against dark tiles.
    static let path = Color(red: 1.0, green: 0.77, blue: 0.24)
    static let pathStart = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let pathEnd = Color(red: 1.0, green: 0.42, blue: 0.36)
    static let good = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelBorder))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Theme.secondaryText)
    }
}
