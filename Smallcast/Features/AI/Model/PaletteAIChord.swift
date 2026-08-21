import Foundation

/// The in-palette chord that hands the typed text to the AI. Deliberately a fixed set rather than a
/// recorder: `ShortcutRecorder` records a *global* Carbon chord, which this is not.
enum PaletteAIChord: String, CaseIterable, Identifiable, Sendable {
    case optionReturn = "option-return"
    case controlReturn = "control-return"
    case tab

    var id: String { rawValue }

    /// The key the chord ends on; the palette owns one handler per key.
    enum Key: Sendable {
        case returnKey
        case tab
    }

    /// Named here rather than as SwiftUI's `EventModifiers`, so this file stays Foundation-only.
    enum Modifier: Sendable {
        case option
        case control
    }

    var key: Key { self == .tab ? .tab : .returnKey }

    var modifier: Modifier? {
        switch self {
        case .optionReturn: return .option
        case .controlReturn: return .control
        case .tab: return nil
        }
    }

    var keycaps: [String] {
        switch self {
        case .optionReturn: return ["⌥", "↵"]
        case .controlReturn: return ["⌃", "↵"]
        case .tab: return ["⇥"]
        }
    }

    var title: String { keycaps.joined(separator: " ") }
}
