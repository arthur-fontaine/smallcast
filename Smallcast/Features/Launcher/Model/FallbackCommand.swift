import Foundation

/// A command that accepts whatever was typed, offered when the search matched nothing. Kept out of
/// `AppEntry.Kind` on purpose: a kind owns a launcher section, a visibility category and a Settings
/// pane, and a fallback wants none of the three. It is a launcher *row*, like the calculator card.
enum FallbackCommandID: Hashable, Sendable {
    case askAI
    case searchWeb
    case searchFiles
    case quicklink(UUID)

    private static let quicklinkPrefix = "quicklink:"

    var rawValue: String {
        switch self {
        case .askAI: return "ask-ai"
        case .searchWeb: return "search-web"
        case .searchFiles: return "search-files"
        case .quicklink(let id): return Self.quicklinkPrefix + id.uuidString.lowercased()
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "ask-ai": self = .askAI
        case "search-web": self = .searchWeb
        case "search-files": self = .searchFiles
        default:
            guard rawValue.hasPrefix(Self.quicklinkPrefix),
                let id = UUID(uuidString: String(rawValue.dropFirst(Self.quicklinkPrefix.count)))
            else { return nil }
            self = .quicklink(id)
        }
    }

    /// Nil for a quicklink, whose name lives in its own record rather than in this table.
    var builtInName: String? {
        switch self {
        case .askAI: return "Ask AI"
        case .searchWeb: return "Search the Web"
        case .searchFiles: return "Search Files"
        case .quicklink: return nil
        }
    }

    var sfSymbol: String {
        switch self {
        case .askAI: return "sparkles"
        case .searchWeb: return "globe"
        case .searchFiles: return "doc.text.magnifyingglass"
        case .quicklink: return Quicklink.sfSymbol
        }
    }

    static let builtIns: [FallbackCommandID] = [.searchWeb, .searchFiles, .askAI]
}

/// One fallback as the launcher draws it: the command plus the name it resolved to, since a
/// quicklink's name lives in its own record rather than in `FallbackCommandID`.
struct FallbackRow: Identifiable, Equatable, Sendable {
    let command: FallbackCommandID
    let name: String

    var id: String { command.rawValue }
    var sfSymbol: String { command.sfSymbol }
}

/// The stored list, and the rules that turn it into the rows a no-result search shows.
enum FallbackCommands {
    /// Ask AI is available but unlisted out of the box: it already has a chord of its own.
    static let defaults: [FallbackCommandID] = [.searchWeb, .searchFiles]

    static let defaultWebTemplate = "https://duckduckgo.com/?q={query}"
    static let queryPlaceholder = "{query}"

    /// What each fallback needs to be worth offering, so the filter stays a decision and not a
    /// scattering of `if settings.…` at the call sites.
    struct Availability: Sendable {
        let aiEnabled: Bool
        let fileSearchEnabled: Bool
        /// The quicklinks that take an argument; anything else has nowhere to put the typed text.
        let argumentQuicklinkIDs: Set<UUID>

        init(aiEnabled: Bool, fileSearchEnabled: Bool, argumentQuicklinkIDs: Set<UUID>) {
            self.aiEnabled = aiEnabled
            self.fileSearchEnabled = fileSearchEnabled
            self.argumentQuicklinkIDs = argumentQuicklinkIDs
        }

        func allows(_ id: FallbackCommandID) -> Bool {
            switch id {
            case .askAI: return aiEnabled
            case .searchFiles: return fileSearchEnabled
            case .searchWeb: return true
            case .quicklink(let quicklink): return argumentQuicklinkIDs.contains(quicklink)
            }
        }
    }

    static func decode(_ stored: [String]) -> [FallbackCommandID] {
        stored.compactMap(FallbackCommandID.init(rawValue:))
    }

    static func encode(_ ids: [FallbackCommandID]) -> [String] {
        ids.map(\.rawValue)
    }

    /// The stored order, deduplicated, minus whatever is turned off or gone. Order is the user's.
    static func resolved(
        stored: [FallbackCommandID], availability: Availability
    ) -> [FallbackCommandID] {
        var seen = Set<FallbackCommandID>()
        return stored.filter { availability.allows($0) && seen.insert($0).inserted }
    }

    /// What the Settings list offers to add: everything allowed that isn't already listed.
    static func candidates(
        stored: [FallbackCommandID], availability: Availability, quicklinkIDs: [UUID]
    ) -> [FallbackCommandID] {
        let listed = Set(stored)
        let all = FallbackCommandID.builtIns + quicklinkIDs.map(FallbackCommandID.quicklink)
        return all.filter { availability.allows($0) && !listed.contains($0) }
    }

    /// The typed text is percent-encoded into the template. A template with no placeholder cannot
    /// carry a query, so it is treated as unusable rather than opened without one.
    static func webURL(template: String, query: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(queryPlaceholder),
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        return URL(string: trimmed.replacingOccurrences(of: queryPlaceholder, with: encoded))
    }
}
