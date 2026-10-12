import Foundation

/// One row of `digup search --json`. DigUp ranks files, so a path appears once.
struct DigUpHit: Decodable, Equatable, Sendable {
    let path: String
    let kind: String
}

/// How File Search asks DigUp's helper and reads its answer. See file-search.md#digup.
enum DigUpSearchPolicy {
    /// Root search shows this many, and asks for one more to learn whether "Show More" earns a row.
    static let rootRowLimit = 5
    /// DigUp returns only matches that stand out, so this caps a long tail rather than paging it.
    static let panelLimit = 500

    /// Nil when there is nothing to ask: a blank query, or a filter DigUp indexes no file for.
    static func arguments(
        query: String, limit: Int, filter: FileSearchFilter, indexDirectory: String?
    ) -> [String]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return nil }
        let kinds = kinds(for: filter)
        if let kinds, kinds.isEmpty { return nil }
        // The helper parses a leading dash as an option; a space keeps it a word to search for.
        let words = trimmed.hasPrefix("-") ? " " + trimmed : trimmed
        var arguments = ["search", words, "-n", String(limit), "--json"]
        if let kinds { arguments += ["--kind", kinds.joined(separator: ",")] }
        if let indexDirectory, !indexDirectory.isEmpty { arguments += ["--index", indexDirectory] }
        return arguments
    }

    /// DigUp's `--kind` names for a header filter: nil searches everything, empty finds nothing.
    static func kinds(for filter: FileSearchFilter) -> [String]? {
        switch filter {
        case .all: return nil
        case .documents: return ["pdf", "doc"]
        case .images: return ["screenshot", "image"]
        case .audio: return ["audio"]
        case .video: return ["video"]
        // DigUp indexes what is inside files, so it never answers with a folder or an archive.
        case .folders, .archives: return []
        }
    }

    static func hits(fromJSON data: Data) throws -> [DigUpHit] {
        try JSONDecoder().decode([DigUpHit].self, from: data)
    }

    /// Kept in DigUp's order, minus files deleted since DigUp indexed them.
    static func results(
        from hits: [DigUpHit], homeDirectory: URL, isDirectory: (String) -> Bool?
    ) -> [FileSearchResult] {
        hits.compactMap { hit in
            guard let directory = isDirectory(hit.path) else { return nil }
            return FileSearchResult(
                url: URL(fileURLWithPath: hit.path), isDirectory: directory,
                homeDirectory: homeDirectory)
        }
    }
}
