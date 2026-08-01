import SwiftUI

enum Theme {
    static let cardRadius: CGFloat = 14
    static let cardBackground = Color(red: 0.07, green: 0.09, blue: 0.14).opacity(0.72)
    static let cardBorder = Color.white.opacity(0.10)
    static let headerText = Color.white.opacity(0.55)
    static let accent = Color(red: 0.93, green: 0.79, blue: 0.44) // warm gold, CNVS-style
    static let terminalBackground = Color(red: 0.05, green: 0.07, blue: 0.11)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardSurface()) }
}
