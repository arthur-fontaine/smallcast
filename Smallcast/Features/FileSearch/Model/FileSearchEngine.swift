import Foundation

/// How File Search finds files, everywhere it answers. See file-search.md#engine.
enum FileSearchEngine: String, CaseIterable, Identifiable, Sendable {
    case name
    /// DigUp on top of the filename index, never instead of it: DigUp reads only the folders and kinds it indexes.
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
        case .name: return "Smallcast’s own index · instant"
        case .nameAndContent:
            return "The index and DigUp · a photo by what it shows, a PDF by what it says"
        }
    }
}
