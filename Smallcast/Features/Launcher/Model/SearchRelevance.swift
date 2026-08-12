import Foundation

enum FuzzyMatch {
    /// A literal hit is the query's own characters, contiguous; the other two are inferences.
    enum Tier: Sendable {
        case exact
        case prefix
        case wordStart
        case substring
        case subsequence
        /// Close enough to be a misspelling of the candidate, or of one of its words.
        case typo

        var isLiteral: Bool { self != .subsequence && self != .typo }
    }

    struct Match: Sendable {
        let tier: Tier
        let score: Int
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

    /// Tiered relevance, or nil; tiers are spaced so a better kind always wins.
    static func match(query: String, candidate: String) -> Match? {
        match(Query(query), candidate: candidate)
    }

    static func match(_ query: Query, candidate: String) -> Match? {
        let q = query.text
        let c = normalized(candidate)
        guard !q.isEmpty else { return Match(tier: .exact, score: 0) }

        if c == q { return Match(tier: .exact, score: 100_000) }
        if c.hasPrefix(q) { return Match(tier: .prefix, score: 90_000 - c.count) }

        if let range = c.range(of: q) {
            let atWordStart = isWordStart(c, range.lowerBound)
            return Match(
                tier: atWordStart ? .wordStart : .substring,
                score: (atWordStart ? 80_000 : 70_000) - c.count)
        }

        if let sub = subsequenceScore(query.characters, c) {
            return Match(tier: .subsequence, score: sub)
        }
        // Last resort: the query is close enough to be a typo of the name, or of one of its words.
        guard let typo = typoScore(query.characters, Array(c)) else { return nil }
        return Match(tier: .typo, score: typo)
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
    private static func typoScore(_ q: [Character], _ c: [Character]) -> Int? {
        let allowed = allowedDistance(forQueryLength: q.count)
        // O(query × candidate) per word start; names are short, but guard the pathological case.
        guard allowed > 0, !c.isEmpty, c.count <= 64 else { return nil }

        var best: Int?
        for start in wordStarts(c) {
            guard let distance = prefixDistance(q, c, from: start, allowed: allowed) else { continue }
            if distance < best ?? Int.max { best = distance }
            if best == 0 { break }
        }
        guard let distance = best else { return nil }
        return 40_000 - distance * 1_000 - min(c.count, 999)
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
    )
        -> Int?
    {
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

    /// Score-only form, for callers that rank one field and don't band by match strength.
    static func score(query: String, candidate: String) -> Int? {
        match(query: query, candidate: candidate)?.score
    }

    /// The widest score `match` returns; the bands are sized off it so they never overlap.
    static let maximumScore = 100_000

    /// No scalar below U+00AD is `.format`, so ASCII names skip the rebuild and the ICU lookup.
    private static func normalized(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value >= 0xAD }) else {
            return value.lowercased()
        }
        guard value.unicodeScalars.contains(where: { $0.properties.generalCategory == .format })
        else { return value.lowercased() }
        let scalars = value.unicodeScalars.filter {
            $0.properties.generalCategory != .format
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

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
}

/// Never flatten these into one string — which field matched is what picks the band.
struct SearchFields: Sendable {
    /// The display name, plus anything identifying the entry just as strongly.
    var names: [String]
    /// Spotlight's `kMDItemAlternateNames`: `iBooks`, `Codex`, `浏览器`.
    var alternateNames: [String] = []
    var bundleID: String?
    var executableName: String?
    /// What the entry *is* — "Window Management", "Application", an extension's title. Matched only
    /// from its start, in the weakest band of all, so a whole group can be pulled up by its kind
    /// without ever outranking something actually named that.
    var category: String?
}

enum SearchRelevance {
    /// One band per field and match strength; a literal hit on a weaker field still wins.
    private enum Band: Int {
        case category = 0
        case nameTypo = 1
        case executableName = 2
        case bundleID = 3
        case alternateNameSubsequence = 4
        case nameSubsequence = 5
        case alternateNameLiteral = 6
        case nameLiteral = 7

        var offset: Int { rawValue * SearchRelevance.bandStride }
    }

    /// Wide enough that a learned boost reorders inside a band, never out of one.
    static let bandStride = 10 * FuzzyMatch.maximumScore
    /// How many bands there are; `fuzz-test` asserts no score ever lands outside them.
    static let bandCount = Band.nameLiteral.rawValue + 1

    /// Base relevance from the strongest matching field, or nil when no field matches.
    static func score(query: String, fields: SearchFields) -> Int? {
        let query = FuzzyMatch.Query(query)
        // Every entry is equally relevant to an empty query, so no field claims a band.
        guard !query.isEmpty else { return 0 }
        var best: Int?

        func consider(_ candidate: String, literal: Band, subsequence: Band?, typo: Band? = nil) {
            guard let match = FuzzyMatch.match(query, candidate: candidate) else { return }
            // No inferred band on identifiers: it would change which apps appear at all.
            let band: Band?
            switch match.tier {
            case .subsequence: band = subsequence
            case .typo: band = typo
            default: band = literal
            }
            guard let band else { return }
            best = max(best ?? Int.min, band.offset + match.score)
        }

        for name in fields.names {
            consider(name, literal: .nameLiteral, subsequence: .nameSubsequence, typo: .nameTypo)
        }
        for alternate in fields.alternateNames {
            consider(alternate, literal: .alternateNameLiteral, subsequence: .alternateNameSubsequence)
        }
        if let bundleID = fields.bundleID {
            consider(identifyingPart(of: bundleID), literal: .bundleID, subsequence: nil)
            // A pasted identifier should still resolve, which the trimmed form alone can't do.
            if let match = FuzzyMatch.match(query, candidate: bundleID), match.tier == .exact {
                best = max(best ?? Int.min, Band.bundleID.offset + match.score)
            }
        }
        if let executableName = fields.executableName {
            consider(executableName, literal: .executableName, subsequence: nil)
        }
        // A category has to be named from its start (or be a near-miss of it): a mid-word substring
        // would make "cat" list every Appli**cat**ion, and a subsequence match is looser still.
        if let category = fields.category, let match = FuzzyMatch.match(query, candidate: category) {
            switch match.tier {
            case .exact, .prefix, .wordStart, .typo:
                best = max(best ?? Int.min, Band.category.offset + match.score)
            case .substring, .subsequence:
                break
            }
        }
        return best
    }

    /// Drops the leading reverse-DNS component, which prefixes nearly every installed app.
    private static func identifyingPart(of bundleID: String) -> String {
        guard let dot = bundleID.firstIndex(of: ".") else { return bundleID }
        return String(bundleID[bundleID.index(after: dot)...])
    }
}

extension SearchFields {
    /// Spotlight mixes junk in with the real aliases; indexing it makes `app` match all.
    static func usableAlternateNames(
        _ raw: [String], displayName: String, fileName: String
    ) -> [String] {
        let rejected = Set([displayName, fileName].map(strippingAppExtension).map { $0.lowercased() })
        var seen = Set<String>()
        return raw.compactMap { candidate in
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isPlaceholder(name) else { return nil }
            let key = strippingAppExtension(name).lowercased()
            guard !key.isEmpty, !rejected.contains(key), seen.insert(key).inserted else { return nil }
            return name
        }
    }

    private static func strippingAppExtension(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// A lone SCREAMING_SNAKE token is an untranslated placeholder, and several ship.
    private static func isPlaceholder(_ name: String) -> Bool {
        name.contains("_") && !name.contains(where: { $0.isLowercase || $0.isWhitespace })
    }
}
