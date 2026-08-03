import Foundation

/// App-internal launcher actions surfaced as a "Commands" category; each is a synthetic `AppEntry` (kind `.command`, no bundle ID) so existing `AppEntry` plumbing applies, with dispatch in `AppCore.runCommand`.
enum CommandID: String, CaseIterable, Sendable {
    case calculatorHistory = "command:calculator-history"
    case clipboardHistory = "command:clipboard-history"
    case searchEmoji = "command:search-emoji"
    case history = "command:history"
    case exportSettings = "command:export-settings"
    case importSettings = "command:import-settings"
    case importFromRaycast = "command:import-from-raycast"
    case settings = "command:settings"
    case about = "command:about"
    case quit = "command:quit"

    var name: String {
        switch self {
        case .calculatorHistory: return "Calculator History"
        case .clipboardHistory: return "Clipboard History"
        case .searchEmoji: return "Search Emoji & Symbols"
        case .history: return "Search History"
        case .exportSettings: return "Export Settings"
        case .importSettings: return "Import Settings"
        case .importFromRaycast: return "Import from Raycast"
        case .settings: return "Settings"
        case .about: return "About Smallcast"
        case .quit: return "Quit Smallcast"
        }
    }

    var sfSymbol: String {
        switch self {
        case .calculatorHistory: return "plus.forwardslash.minus"
        case .clipboardHistory: return "doc.on.clipboard"
        case .searchEmoji: return "face.smiling"
        case .history: return "clock.arrow.circlepath"
        case .exportSettings: return "square.and.arrow.up"
        case .importSettings: return "square.and.arrow.down"
        case .importFromRaycast: return "arrow.down.doc"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        case .quit: return "power"
        }
    }
}

enum CommandRegistry {
    /// Sorted by name to keep the AppIndex sort invariant; the URL is a placeholder since commands are never launched from disk. The window-arrangement commands only exist while the feature is on — read straight from UserDefaults because this is built off the main actor, on the scan queue.
    nonisolated static var all: [AppEntry] {
        var entries = CommandID.allCases.map { id in
            entry(id: id.rawValue, name: id.name)
        }
        if UserDefaults.standard.bool(forKey: SettingsKey.windowManagementEnabled) {
            entries += WindowAction.allCases.map { action in
                var entry = entry(id: action.entryID, name: action.title)
                entry.kindLabelOverride = "Window Management"
                return entry
            }
        }
        return entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func entry(id: String, name: String) -> AppEntry {
        AppEntry(
            id: id, name: name,
            url: URL(string: "smallcast://" + id.replacingOccurrences(of: ":", with: "/"))!,
            bundleID: nil, kind: .command)
    }

    static func command(for entry: AppEntry) -> CommandID? {
        CommandID(rawValue: entry.id)
    }
}
