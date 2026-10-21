import Foundation

/// The index's names and DigUp's contents on one scale. See file-search.md#ranking.
enum FileSearchRanking {
    /// How a file's own name answers the query, weakest first.
    enum NameMatch: Int, Comparable, Sendable {
        case inWord, wordStart, prefix, exact

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var score: Int {
            switch self {
            case .exact: return 100
            case .prefix: return 92
            case .wordStart: return 84
            case .inWord: return 40
            }
        }
    }

    struct Ranked: Equatable, Sendable {
        var results: [FileSearchResult] = []
        /// The leading rows that are the best of both sources; 0 sets nothing apart.
        var bestCount = 0
    }

    /// Root search's Files section, and the Best Matches File Search leads with.
    static var bestLimit: Int { FileSearchQuery.launcherLimit }
    /// DigUp's first strong match; a word-start name scores above it, so a typed name leads.
    static let strongTop = 80
    /// A name's step per rank: a file found both ways can tie the name above it, never pass it.
    static let bothSourcesBonus = 2

    private struct Candidate {
        var result: FileSearchResult
        var nameScore: Int?
        var nameRank: Int?
        var strongRank: Int?
        var weakRank: Int?

        var hasContent: Bool { strongRank != nil || weakRank != nil }

        var score: Int {
            var best = nameScore ?? 0
            if let strongRank { best = max(best, max(strongTop - 4 * strongRank, 50)) }
            if let weakRank { best = max(best, max(35 - weakRank, 10)) }
            return best + (nameScore != nil && hasContent ? bothSourcesBonus : 0)
        }

        /// Ties keep the sources' own orders, names first.
        var order: (Int, Int) {
            if let nameRank { return (0, nameRank) }
            return (1, strongRank ?? (1_000 + (weakRank ?? 0)))
        }
    }

    /// The top row is a name no content match can outrank, so it needn't wait for DigUp.
    static func isConfident(_ names: [FileSearchResult], query: String) -> Bool {
        guard let first = names.first else { return false }
        return (nameMatch(first.name, query: Prepared(query)) ?? .inWord) >= .wordStart
    }

    static func ranked(names: [FileSearchResult], content: DigUpMatches, query: String) -> Ranked {
        guard !content.isEmpty else { return Ranked(results: names) }
        let prepared = Prepared(query)
        var candidates: [Candidate] = []
        var position: [String: Int] = [:]
        func candidate(for result: FileSearchResult) -> Int {
            if let index = position[result.id] { return index }
            position[result.id] = candidates.count
            candidates.append(Candidate(result: result))
            return candidates.count - 1
        }
        // Capped by the row above, so names keep the index's order: it also weighs where they live.
        var ceiling = Int.max
        for (rank, result) in names.enumerated() {
            let index = candidate(for: result)
            // The index matched it on its own terms, so a name it found is a name match at least.
            let match = nameMatch(result.name, query: prepared) ?? .inWord
            ceiling = min(ceiling, match.score - min(2 * rank, match == .inWord ? 20 : 30))
            candidates[index].nameScore = ceiling
            candidates[index].nameRank = rank
        }
        for (rank, result) in content.strong.enumerated() {
            let index = candidate(for: result)
            // Only DigUp's copy carries the passage that matched.
            candidates[index].result = result
            if candidates[index].strongRank == nil { candidates[index].strongRank = rank }
        }
        for (rank, result) in content.weak.enumerated() {
            let index = candidate(for: result)
            candidates[index].result = result
            if candidates[index].weakRank == nil { candidates[index].weakRank = rank }
        }
        for index in candidates.indices where candidates[index].nameRank == nil {
            candidates[index].nameScore = nameMatch(candidates[index].result.name, query: prepared)?.score
        }

        var sorted = candidates.sorted { lhs, rhs in
            let left = lhs.score, right = rhs.score
            if left != right { return left > right }
            return lhs.order < rhs.order
        }
        guard sorted.contains(where: { $0.nameScore != nil }), sorted.count > bestLimit else {
            return Ranked(results: sorted.map(\.result))
        }
        // Neither source is ever shut out of the best: its own best takes the last place there.
        let evidence: [(Candidate) -> Bool] = [{ $0.nameScore != nil }, { $0.strongRank != nil }]
        for has in evidence where !sorted.prefix(bestLimit).contains(where: has) {
            guard let index = sorted.firstIndex(where: has) else { continue }
            sorted.insert(sorted.remove(at: index), at: bestLimit - 1)
        }
        return Ranked(results: sorted.map(\.result), bestCount: bestLimit)
    }

    /// Rows already drawn keep their places, even one a later pass dropped; new rows join after them.
    static func holding(_ shown: [FileSearchResult], against ranked: [FileSearchResult]) -> [FileSearchResult] {
        let fresh = Dictionary(ranked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(shown.map(\.id))
        return shown.map { fresh[$0.id] ?? $0 } + ranked.filter { !kept.contains($0.id) }
    }

    /// The query folded once, as the index folds it.
    struct Prepared {
        let terms: [[Character]]
        let whole: [Character]

        init(_ query: String) {
            terms = FileSearchQuery.terms(in: query).map { Array(FileSearchQuery.fold($0)) }
            whole = Array(terms.joined(separator: [" "]))
        }
    }

    static func nameMatch(_ name: String, query: String) -> NameMatch? {
        nameMatch(name, query: Prepared(query))
    }

    private static func nameMatch(_ name: String, query: Prepared) -> NameMatch? {
        guard !query.terms.isEmpty else { return nil }
        let folded = Array(FileSearchQuery.fold(name))
        let stem = folded.lastIndex(of: ".").map { Array(folded[..<$0]) } ?? folded
        if stem == query.whole || folded == query.whole { return .exact }
        if folded.starts(with: query.whole) { return .prefix }
        // Folding can change the length; camel case is then read on the folded text alone.
        let original = Array(name)
        let cased = original.count == folded.count ? original : folded
        var atWordStart = true
        for term in query.terms {
            let starts = occurrences(of: term, in: folded)
            guard !starts.isEmpty else { return nil }
            if !starts.contains(where: { isWordStart($0, in: folded, cased: cased) }) { atWordStart = false }
        }
        return atWordStart ? .wordStart : .inWord
    }

    private static func occurrences(of term: [Character], in text: [Character]) -> [Int] {
        guard !term.isEmpty, term.count <= text.count else { return [] }
        return (0...(text.count - term.count)).filter { text[$0..<($0 + term.count)].elementsEqual(term) }
    }

    /// The index's own boundary: after a separator, or where a lowercase letter meets a capital.
    private static func isWordStart(_ index: Int, in folded: [Character], cased: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = folded[index - 1]
        guard previous.isLetter || previous.isNumber else { return true }
        return cased[index - 1].isLowercase && cased[index].isUppercase
    }
}
