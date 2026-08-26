import Foundation

/// Ordered like a bare backspace: a screen is only left once the search field is empty.
enum PaletteEscapeAction: Equatable {
    case closeMenu
    case clearQuery
    case exitExtensionScreen
    case exitScreen
    case hidePalette

    static func resolve(menuOpen: Bool, query: String, mode: PaletteMode) -> Self {
        if menuOpen { return .closeMenu }
        if !query.isEmpty { return .clearQuery }
        // An extension pops its own navigation stack before the command is left.
        if mode == .extensionCommand { return .exitExtensionScreen }
        // Every other sub-screen backs out to the launcher; only the launcher itself closes.
        if mode != .launcher { return .exitScreen }
        return .hidePalette
    }
}
