import Foundation

enum FuzzyMatch {
    /// A literal hit is the query's own characters, contiguous; the other two are inferences.
    enum Tier: Sendable, CaseIterable {
        case exact
        case prefix
        case wordStart
        case substring
        case subsequence
        /// Close enough to be a misspelling of the candidate, or of one of its words.
        case typo

        var isLiteral: Bool { self != .subsequence && self != .typo }
        /// Anchored at the candidate's start: what a short, deliberate field must match.
        var isAnchored: Bool { self == .exact || self == .prefix }
    }

    struct Match: Sendable {
        let tier: Tier
        /// Characters into the candidate the hit begins; 0 for both anchored tiers.
        let offset: Int
        let queryLength: Int
        let candidateLength: Int
        /// The subsequence walk's raw bonus total, a typo's edit distance, 0 for every literal tier.
        let spread: Int

        /// One ordering for a caller ranking a single field, with no role to weigh.
        var score: Int { FuzzyMatch.rawScore(self) }
    }

    /// A query folded once, so ranking doesn't re-fold it for every candidate field.
    struct Query: Sendable {
        fileprivate let text: String
        /// Folded once too: the subsequence pass needs random access on every candidate.
        fileprivate let characters: [Character]
        var isEmpty: Bool { text.isEmpty }

        init(_ raw: String) {
            text = FuzzyMatch.normalized(raw)
            characters = Array(text)
        }
    }

    /// The tier a query hits a candidate at, with the geometry `SearchRelevance.shape` reads.
    static func match(query: String, candidate: String) -> Match? {
        match(Query(query), candidate: candidate)
    }

    static func match(_ query: Query, candidate: String) -> Match? {
        let q = query.text
        let c = normalized(candidate)
        let length = c.count
        guard !q.isEmpty else {
            return Match(
                tier: .exact, offset: 0, queryLength: 0, candidateLength: length, spread: 0)
        }

        if c == q {
            return Match(
                tier: .exact, offset: 0, queryLength: query.characters.count,
                candidateLength: length, spread: 0)
        }
        if c.hasPrefix(q) {
            return Match(
                tier: .prefix, offset: 0, queryLength: query.characters.count,
                candidateLength: length, spread: 0)
        }
        if let range = c.range(of: q) {
            let offset = c.distance(from: c.startIndex, to: range.lowerBound)
            return Match(
                tier: isWordStart(c, range.lowerBound) ? .wordStart : .substring, offset: offset,
                queryLength: query.characters.count, candidateLength: length, spread: 0)
        }
        if let spread = subsequenceScore(query.characters, c) {
            return Match(
                tier: .subsequence, offset: 0, queryLength: query.characters.count,
                candidateLength: length, spread: spread)
        }
        // Last resort: the query is close enough to be a typo of the name, or of one of its words.
        guard let distance = typoDistance(query.characters, Array(c)) else { return nil }
        return Match(
            tier: .typo, offset: 0, queryLength: query.characters.count,
            candidateLength: length, spread: distance)
    }

    /// Score-only form, for callers that rank one field and don't band by match strength.
    static func score(query: String, candidate: String) -> Int? {
        match(query: query, candidate: candidate).map(rawScore)
    }

    /// The folded form, for a caller sweeping many candidates against one query.
    static func score(_ query: Query, candidate: String) -> Int? {
        match(query, candidate: candidate).map(rawScore)
    }

    /// FileSearch ranks one field and wants a single ordering, not a role-aware one.
    fileprivate static func rawScore(_ match: Match) -> Int {
        switch match.tier {
        case .exact: 100_000
        case .prefix: 90_000 - match.candidateLength
        case .wordStart: 80_000 - match.candidateLength
        case .substring: 70_000 - match.candidateLength
        case .subsequence: match.spread
        // Below any subsequence hit, whose walk scores at least 13 for its first character.
        case .typo: max(0, 12 - match.spread)
        }
    }

    /// The one fold in the launcher: matching, learned-ranking keys and dedup all call it.
    static func normalized(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value >= 0xAD }) else {
            return value.lowercased()
        }
        // Composed first, so a Korean or Vietnamese IME's decomposed input folds like typed text.
        let composed = value.precomposedStringWithCanonicalMapping
        let scalars = composed.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(scalars)).folding(options: folding, locale: nil)
    }

    /// Locale-independent: a Turkish fold maps "I" to "ı" and orphans every stored key.
    static let folding: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive
    ]

    private static func isWordStart(_ s: String, _ index: String.Index) -> Bool {
        if index == s.startIndex { return true }
        let before = s[s.index(before: index)]
        return !before.isLetter && !before.isNumber
    }

    /// Walks in place, carrying the previous character: `Array(c)` was an allocation per keystroke.
    private static func subsequenceScore(_ q: [Character], _ c: String) -> Int? {
        var qi = 0
        var score = 0
        var run = 0
        var prev = -2
        var ci = 0
        var previous: Character?
        for ch in c {
            if qi < q.count, ch == q[qi] {
                var bonus = 1
                if ci == prev + 1 {
                    run += 1
                    bonus += run * 3
                } else {
                    run = 0
                }
                if ci == 0 {
                    bonus += 12
                } else if let previous, !previous.isLetter, !previous.isNumber {
                    bonus += 8
                }
                score += bonus
                prev = ci
                qi += 1
                if qi == q.count { break }
            }
            previous = ch
            ci += 1
        }
        guard qi == q.count else { return nil }
        return score
    }

    /// How wrong a query of this length is allowed to be — roughly one edit per eight characters,
    /// never more than a fifth of what was typed. Short queries get no slack at all: at three
    /// characters almost everything is within one edit, and the subsequence tier already covers
    /// initialisms like "tm" → Time Machine. Two edits on a six-letter word was too loose — it made
    /// "finder" a match for "Find My".
    static func allowedDistance(forQueryLength length: Int) -> Int {
        switch length {
        case ..<4: return 0
        case 4...7: return 1
        case 8...11: return 2
        default: return 3
        }
    }

    /// Edit distance from the query to the start of the candidate — or to the start of any of its
    /// words, so "managment" still finds "Window Management". Nil when nothing is close enough.
    private static func typoDistance(_ q: [Character], _ c: [Character]) -> Int? {
        let allowed = allowedDistance(forQueryLength: q.count)
        // O(query × candidate) per word start; names are short, but guard the pathological case.
        guard allowed > 0, !c.isEmpty, c.count <= 64 else { return nil }
        var best: Int?
        for start in wordStarts(c) {
            guard let distance = prefixDistance(q, c, from: start, allowed: allowed) else { continue }
            if distance < best ?? Int.max { best = distance }
            if best == 0 { break }
        }
        return best
    }

    private static func wordStarts(_ c: [Character]) -> [Int] {
        var starts = [0]
        for index in 1..<c.count {
            let before = c[index - 1]
            if !before.isLetter && !before.isNumber { starts.append(index) }
        }
        return starts
    }

    /// Bounded Damerau–Levenshtein from `q` to the best *prefix* of `c[from...]` — trailing candidate
    /// characters are free, so a query only has to be a near-miss of the beginning ("clipbrd" →
    /// "Clipboard History"). Returns nil as soon as every alignment is worse than `allowed`.
    private static func prefixDistance(
        _ q: [Character], _ c: [Character], from: Int, allowed: Int
    ) -> Int? {
        let rows = q.count
        let columns = c.count - from
        guard columns > 0 else { return nil }
        var previous2 = [Int](repeating: 0, count: columns + 1)  // one row back, for transpositions
        // Row 0: matching none of the query against `column` candidate characters costs `column` —
        // skipped *leading* characters are edits; only the trailing remainder is free (below).
        var previous = Array(0...columns)
        var current = [Int](repeating: 0, count: columns + 1)
        for row in 1...rows {
            current[0] = row
            var rowBest = current[0]
            for column in 1...columns {
                let cost = q[row - 1] == c[from + column - 1] ? 0 : 1
                var value = min(
                    previous[column] + 1,  // delete from query
                    current[column - 1] + 1,  // insert candidate character
                    previous[column - 1] + cost)  // substitute
                if row > 1, column > 1, q[row - 1] == c[from + column - 2],
                    q[row - 2] == c[from + column - 1]
                {
                    value = min(value, previous2[column - 2] + 1)  // transposition
                }
                current[column] = value
                rowBest = min(rowBest, value)
            }
            // Every alignment through this row is already too expensive — no later row can recover.
            guard rowBest <= allowed else { return nil }
            previous2 = previous
            previous = current
        }
        // Free trailing: the query may match any prefix of the candidate, so take the best column.
        let distance = previous.min() ?? Int.max
        return distance <= allowed ? distance : nil
    }

    /// What a contiguous run from index 0 would score, so `spread` normalizes to a fraction.
    static func referenceSpread(_ queryLength: Int) -> Int {
        guard queryLength > 0 else { return 1 }
        return 13 + (queryLength - 1) + 3 * queryLength * (queryLength - 1) / 2
    }
}

/// One string an entry can be found by; ranking reads `role` and `looseness` and nothing else.
struct SearchAlias: Sendable, Hashable {
    /// A closed ladder: a new criterion picks a role from it and never adds a case.
    enum Role: Int, Sendable, CaseIterable {
        /// Machine-facing: bundle id, executable name.
        case technical = 0
        /// What provides the entry rather than what it is — the extension a command came from.
        case owner = 1
        /// Another way to say the same name: a localization, an alternate, a romanization.
        case translation = 2
        /// The name the entry is presented under, and anything identifying it just as strongly.
        case name = 3
        /// The user's own word for the entry; deliberate, so it outranks every vendor string.
        case userAlias = 4

        /// The loosest match this role trusts. Shared or machine text floods on a fuzzy hit.
        var looseness: Looseness {
            switch self {
            case .translation, .name: .fuzzy
            case .technical, .owner, .userAlias: .literal
            }
        }
    }

    /// How weak a match an alias will accept. Tightening one is how a flood-prone string opts out.
    enum Looseness: Sendable, Hashable {
        case fuzzy
        case literal
        case exact

        func accepts(_ tier: FuzzyMatch.Tier) -> Bool {
            switch self {
            case .fuzzy: true
            case .literal: tier.isLiteral
            case .exact: tier == .exact
            }
        }
    }

    let text: String
    let role: Role
    let looseness: Looseness

    init(_ text: String, _ role: Role, looseness: Looseness? = nil) {
        self.text = text
        self.role = role
        self.looseness = looseness ?? role.looseness
    }

    static func name(_ text: String) -> Self { Self(text, .name) }
    static func translation(_ text: String) -> Self { Self(text, .translation) }
    static func owner(_ text: String) -> Self { Self(text, .owner) }
    static func technical(_ text: String) -> Self { Self(text, .technical) }
    static func userAlias(_ text: String) -> Self { Self(text, .userAlias) }
}

/// Never flatten these into one string — which alias matched is half of what picks the cell.
struct SearchFields: Sendable, Hashable, ExpressibleByArrayLiteral {
    var aliases: [SearchAlias]

    init(_ aliases: [SearchAlias] = []) { self.aliases = aliases }
    init(arrayLiteral elements: SearchAlias...) { aliases = elements }

    mutating func append(_ alias: SearchAlias) { aliases.append(alias) }
}

/// How well a query fits an entry: every gap below is a pick count, and one gap is a firewall.
enum SearchRelevance {
    /// The lowest protected cell. Nothing below it is reachable at any usage.
    static let protectionFloor = 6_500
    /// The strongest unprotected cell, and the weakest evidence the index will show at all.
    static let poolTop = 3_100
    static let poolBottom = 600
    /// Below the pool: a typo is a guess about the name, not evidence the index would show alone.
    static let typoCell = 500
    /// `shape` orders inside one cell and can never leave it.
    static let shapeSpan = 99
    /// The exclusive bound every usage term must respect, or the firewall stops holding.
    static let usageCeiling = 3_000

    /// The closed table. A new naming criterion picks a role; it never adds a row here.
    static func cell(_ role: SearchAlias.Role, _ tier: FuzzyMatch.Tier) -> Int? {
        switch (role, tier) {
        case (.userAlias, .exact): 7_000
        case (.name, .exact): protectionFloor
        case (.userAlias, .prefix): poolTop
        case (.name, .prefix): 3_000
        case (.translation, .exact): 2_700
        case (.owner, .exact): 2_500
        case (.name, .wordStart): 2_400
        case (.translation, .prefix): 2_200
        case (.owner, .prefix): 2_000
        case (.name, .substring): 1_800
        case (.translation, .wordStart): 1_700
        case (.owner, .wordStart): 1_500
        case (.technical, .exact): 1_400
        case (.translation, .substring): 1_200
        case (.owner, .substring): 1_100
        case (.name, .subsequence): 1_000
        case (.technical, .prefix): 900
        case (.translation, .subsequence): 800
        case (.technical, .wordStart): 700
        case (.technical, .substring): poolBottom
        // A misspelling of the display name alone: under every real hit, never a translation's.
        case (.name, .typo): typoCell
        // `Looseness` refuses these, so no query can reach them.
        case (.userAlias, _), (.owner, .subsequence), (.technical, .subsequence),
            (.translation, .typo), (.owner, .typo), (.technical, .typo):
            nil
        }
    }

    /// Orders candidates inside one cell: how much of the name the query covered, and how early.
    static func shape(_ match: FuzzyMatch.Match) -> Int {
        guard match.candidateLength > 0 else { return 0 }
        let coverage = min(1, Double(match.queryLength) / Double(match.candidateLength))
        // Absolute, not proportional: a hit five characters in is equally deep in any name.
        let positional: Double
        switch match.tier {
        case .subsequence:
            positional = min(
                1, Double(match.spread) / Double(FuzzyMatch.referenceSpread(match.queryLength)))
        case .typo: positional = 1 / (1 + Double(match.spread))
        default: positional = 1 / (1 + Double(match.offset) / 4)
        }
        return Int((Double(shapeSpan) * (0.6 * coverage + 0.4 * positional)).rounded())
    }

    /// Base relevance from the strongest matching alias, or nil when none matches.
    static func quality(query: String, fields: SearchFields) -> Int? {
        quality(FuzzyMatch.Query(query), fields: fields)
    }

    /// The folded form: an index folds one query once, not once per entry.
    static func quality(_ query: FuzzyMatch.Query, fields: SearchFields) -> Int? {
        // Every entry is equally relevant to an empty query, so no alias claims a cell.
        guard !query.isEmpty else { return 0 }
        var best: Int?
        for alias in fields.aliases {
            guard let match = FuzzyMatch.match(query, candidate: alias.text),
                alias.looseness.accepts(match.tier)
            else { continue }
            // A user alias earns its own cell only from its start; inside, it is a translation.
            let role: SearchAlias.Role =
                alias.role == .userAlias && !match.tier.isAnchored ? .translation : alias.role
            guard let cell = cell(role, match.tier) else { continue }
            best = max(best ?? Int.min, cell + shape(match))
        }
        return best
    }
}
