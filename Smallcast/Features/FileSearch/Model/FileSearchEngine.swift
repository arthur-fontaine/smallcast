import Foundation

/// How File Search finds files, everywhere it answers. See file-search.md#engine.
enum FileSearchEngine: String, CaseIterable, Identifiable, Sendable {
    case name
    /// DigUp on top of Spotlight, never instead of it: DigUp reads only the folders and kinds it indexes.
    case nameAndContent = "content"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .nameAndContent: return "Name and content"
        }
    }

    var summary: String {
        switch self {
        case .name: return "Spotlight, built into macOS · instant"
        case .nameAndContent:
            return "Spotlight and DigUp · a photo by what it shows, a PDF by what it says"
        }
    }
}
