import SwiftUI

/// How the palette and its floating siblings are drawn; Light or Dark is `AppAppearance`'s call.
enum PaletteTheme: String, CaseIterable, Identifiable, Sendable {
    /// The scrim over behind-window blur, with the header and footer floating over one panel.
    case smallcast
    /// Spotlight's look: one glass surface, a capsule at rest that grows into the results card.
    case liquidGlass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smallcast: "Smallcast"
        case .liquidGlass: "Liquid Glass"
        }
    }
}

extension EnvironmentValues {
    /// Read by the palette's chrome; a Settings preview injects its own to draw the other theme.
    @Entry var paletteTheme: PaletteTheme = .smallcast
}
