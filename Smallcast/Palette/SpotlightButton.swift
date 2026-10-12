import Foundation

/// A button beside the Liquid Glass compact bar, as Spotlight keeps Applications beside its own.
enum SpotlightButton: String, CaseIterable, Identifiable, Sendable {
    case applications
    case files
    case quickAI
    case clipboard
    case emoji
    case calculatorHistory
    case quicklinks
    case snippets
    case switchWindows

    /// Spotlight's own count; ⌘2…⌘5 is all the number row has left after ⌘1 for the search.
    static let maximumCount = 4
    /// Spotlight's four, with Quick AI where Spotlight puts Actions.
    static let defaults: [SpotlightButton] = [.applications, .files, .quickAI, .clipboard]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .applications: "Applications"
        case .files: "Files"
        case .quickAI: "Quick AI"
        case .clipboard: "Clipboard"
        case .emoji: "Emoji & Symbols"
        case .calculatorHistory: "Calculator History"
        case .quicklinks: "Quicklinks"
        case .snippets: "Snippets"
        case .switchWindows: "Windows"
        }
    }

    /// The screen it opens, which is also the screen whose own ⌘-digit slots outrank the buttons'.
    var mode: PaletteMode {
        switch self {
        case .applications: .applications
        case .files: .fileSearch
        case .quickAI: .ai
        case .clipboard: .clipboard
        case .emoji: .emoji
        case .calculatorHistory: .calculatorHistory
        case .quicklinks: .quicklinks
        case .snippets: .snippets
        case .switchWindows: .switchWindows
        }
    }

    /// Outline line art, as Spotlight's own are; a filled glyph sits heavier than its neighbours.
    var systemImage: String {
        switch self {
        case .files: "folder"
        case .quickAI: "text.bubble"
        default: mode.systemImage
        }
    }

    /// One slot's picker: a button already in another slot trades places rather than repeating.
    static func assigning(
        _ button: SpotlightButton?, toSlot slot: Int, in buttons: [SpotlightButton]
    ) -> [SpotlightButton] {
        var result = buttons
        guard let button else {
            if result.indices.contains(slot) { result.remove(at: slot) }
            return result
        }
        let existing = result.firstIndex(of: button)
        if result.indices.contains(slot) {
            if let existing { result[existing] = result[slot] }
            result[slot] = button
        } else {
            if let existing { result.remove(at: existing) }
            result.append(button)
        }
        return normalize(result)
    }

    /// Order kept, a repeat and anything past the cap dropped, so a hand-edited file stays valid.
    static func normalize(_ buttons: [SpotlightButton]) -> [SpotlightButton] {
        var seen: Set<SpotlightButton> = []
        return Array(buttons.filter { seen.insert($0).inserted }.prefix(maximumCount))
    }
}

/// What ⌘1…⌘0 do on the Liquid Glass bar's buttons, or on a screen one of them opened.
enum SpotlightButtonChord: Equatable {
    /// ⌘1, Spotlight's own: back to the search field.
    case search
    case open(SpotlightButton)
    /// A digit with no button behind it; the hidden compact favorites must not answer it.
    case consumed

    /// Nil leaves the digit where it went before: a favorite, or a pinned clipboard entry.
    static func resolve(
        isLiquidGlass: Bool, compactMode: Bool, buttons: [SpotlightButton], collapsed: Bool,
        mode: PaletteMode, index: Int
    ) -> Self? {
        guard isLiquidGlass, compactMode, !buttons.isEmpty else { return nil }
        if collapsed { return chord(at: index, buttons: buttons) ?? .consumed }
        // A screen with digit slots of its own keeps them, as the clipboard keeps its pinned rows.
        guard buttons.contains(where: { $0.mode == mode }), !ownsDigits(mode) else { return nil }
        return chord(at: index, buttons: buttons)
    }

    private static func chord(at index: Int, buttons: [SpotlightButton]) -> Self? {
        if index == 0 { return .search }
        return buttons.indices.contains(index - 1) ? .open(buttons[index - 1]) : nil
    }

    private static func ownsDigits(_ mode: PaletteMode) -> Bool {
        mode == .launcher || mode == .clipboard
    }
}
