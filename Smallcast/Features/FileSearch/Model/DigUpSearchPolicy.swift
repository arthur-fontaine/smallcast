import Foundation

/// One hit of `digup search-service`. DigUp ranks files, so a path appears once.
struct DigUpHit: Decodable, Equatable, Sendable {
    let path: String
    let kind: String
    /// The passage that matched, its words wrapped in « », when the match was in the text.
    var excerpt: String?
}

/// One line of the service's stdout: a reply carries its request's `id`, an event does not.
struct DigUpServiceMessage: Decodable, Equatable, Sendable {
    var id: Int?
    var event: String?
    var state: String?
    var hits: [DigUpHit]?
    /// How many leading hits stand out; DigUp's own panel folds the rest away as weaker matches.
    var strong: Int?
    /// The encoder's state, answered by `prewarm` and `status`.
    var encoder: String?
    var error: String?
}

/// What DigUp is asked to search, as one line of the service's stdin.
struct DigUpServiceRequest: Encodable, Equatable, Sendable {
    let id: Int
    let op: String
    var q: String?
    var kinds: [String]?
    var limit: Int?
    var meaning: Bool?
    var prefixLast: Bool?
    var roots: [String]?
    var skipped: [String]?
    var types: [String]?

    enum CodingKeys: String, CodingKey {
        case id, op, q, kinds, limit, meaning, roots, skipped, types
        case prefixLast = "prefix_last"
    }

    func line() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Encoding a struct of strings, ints and bools cannot fail.
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

/// DigUp's answer split where it stops standing out, each half already in File Search's scopes.
struct DigUpMatches: Equatable, Sendable {
    var strong: [FileSearchResult] = []
    var weak: [FileSearchResult] = []

    var isEmpty: Bool { strong.isEmpty && weak.isEmpty }
}

/// The folders DigUp's own settings choose, which its app hands its searcher the same way.
struct DigUpFolders: Equatable, Sendable {
    var roots: [String] = []
    var skipped: [String] = []
    var types: [String] = []
}

/// How File Search asks DigUp's search service and reads its answer. See file-search.md#engine.
enum DigUpSearchPolicy {
    /// DigUp returns only matches that stand out, so this caps a long tail rather than paging it.
    static let panelLimit = 500
    /// Names wait this long for DigUp's answer, so a warm search redraws the list once, not twice.
    static let contentGrace: Duration = .milliseconds(80)
    /// A wait shorter than this goes unremarked, so a warm search never flashes a spinner.
    static let progressDelay: Duration = .milliseconds(300)

    static func serviceArguments(folders: DigUpFolders, indexDirectory: String?) -> [String] {
        var arguments = ["search-service"] + folders.roots
        for folder in folders.skipped { arguments += ["--exclude", folder] }
        if !folders.types.isEmpty { arguments += ["--exclude-ext", folders.types.joined(separator: ",")] }
        if let indexDirectory, !indexDirectory.isEmpty { arguments += ["--index", indexDirectory] }
        return arguments
    }

    /// Nil when there is nothing to ask: a blank query, or a filter DigUp indexes no file for.
    static func searchRequest(
        id: Int, query: String, filter: FileSearchFilter, limit: Int, meaning: Bool
    ) -> DigUpServiceRequest? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return nil }
        let kinds = kinds(for: filter)
        if let kinds, kinds.isEmpty { return nil }
        // Without meaning, the last word is still being typed, so it matches as a prefix.
        return DigUpServiceRequest(
            id: id, op: "search", q: trimmed, kinds: kinds, limit: limit, meaning: meaning,
            prefixLast: !meaning)
    }

    /// DigUp's kind names for a header filter: nil searches everything, empty finds nothing.
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

    static func message(fromLine line: String) -> DigUpServiceMessage? {
        try? JSONDecoder().decode(DigUpServiceMessage.self, from: Data(line.utf8))
    }

    /// DigUp's strong matches, the names, then its weaker ones: a long tail never buries a name.
    static func merged(content: DigUpMatches, names: [FileSearchResult]) -> [FileSearchResult] {
        var seen = Set<String>()
        return (content.strong + names + content.weak).filter { seen.insert($0.id).inserted }
    }

    /// Kept in DigUp's order, minus what File Search's own scopes and ignore rules leave out.
    static func matches(from hits: [DigUpHit], strong: Int?, policy: FileSearchPolicy) -> DigUpMatches {
        let cut = min(strong ?? hits.count, hits.count)
        return DigUpMatches(
            strong: results(from: hits[..<cut], policy: policy),
            weak: results(from: hits[cut...], policy: policy))
    }

    static func results(from hits: some Sequence<DigUpHit>, policy: FileSearchPolicy) -> [FileSearchResult] {
        hits.compactMap { hit in
            guard admits(hit.path, policy: policy) else { return nil }
            return FileSearchResult(
                url: URL(filePath: hit.path), isDirectory: false,
                homeDirectory: policy.homeDirectory, excerpt: hit.excerpt)
        }
    }

    /// The crawl skips an ignored folder whole, so every folder on the way down is checked.
    static func admits(_ path: String, policy: FileSearchPolicy) -> Bool {
        guard let root = policy.roots.first(where: { FileSearchScope.contains($0, path) }) else {
            return false
        }
        var walked = root == "/" ? "" : root
        for component in path.dropFirst(walked.count).split(separator: "/") {
            walked += "/" + component
            if policy.ignore.excludes(name: String(component), path: walked) { return false }
        }
        return true
    }

    /// An excerpt split at DigUp's « » marks, each run saying whether it is a matched word.
    static func excerptRuns(_ excerpt: String) -> [(text: String, matched: Bool)] {
        var runs: [(text: String, matched: Bool)] = []
        var rest = excerpt[...]
        while let open = rest.firstIndex(of: "«") {
            if open > rest.startIndex { runs.append((String(rest[..<open]), false)) }
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "»") else {
                rest = rest[after...]
                break
            }
            runs.append((String(rest[after..<close]), true))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { runs.append((String(rest), false)) }
        return runs
    }

    /// DigUp's roots that File Search can reach: a root inside a scope, or a scope inside a root.
    static func reachableRoots(_ folders: DigUpFolders, policy: FileSearchPolicy) -> [String] {
        folders.roots.filter { root in
            policy.roots.contains { FileSearchScope.contains($0, root) || FileSearchScope.contains(root, $0) }
        }
    }
}
