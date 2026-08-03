import Foundation

/// Ranking shared by the launcher and by an extension `List` that lets Smallcast do the filtering.
/// Foundation-only so `Tools/fuzz-test.swift` and `Tools/ext-test.swift` compile the real source.
enum FuzzyMatch {
    /// Tiered relevance score (higher is better), or nil when the query doesn't match. Each kind of
    /// match owns a 10 000-wide band, so a better kind always wins and `tier(of:)` can recover which
    /// one matched — that's what lets the launcher order by usage *within* a tier without ever
    /// promoting a worse kind of match.
    static func score(query: String, candidate: String) -> Int? {
        let q = query.lowercased()
        let c = candidate.lowercased()
        guard !q.isEmpty else { return 0 }

        if c == q { return 100_000 }
        if c.hasPrefix(q) { return 90_000 - c.count }

        if let range = c.range(of: q) {
            let atWordStart = isWordStart(c, range.lowerBound)
            return (atWordStart ? 80_000 : 70_000) - c.count
        }

        let queryChars = Array(q)
        let candidateChars = Array(c)
        if let sub = subsequenceScore(queryChars, candidateChars) {
            return 50_000 + min(sub, 9_999)
        }
        // Last resort: the query is close enough to be a typo of the name (or of one of its words).
        return typoScore(queryChars, candidateChars)
    }

    /// What kind of match produced a score. Raw values are the score bands, so comparing them orders
    /// matches by quality — which is how callers keep their own tiebreaks (usage, recency) from
    /// reordering across kinds.
    enum Kind: Int, Comparable, Sendable {
        case typo = 3
        case subsequence = 5
        case substring = 6
        case wordStart = 7
        case prefix = 8
        case exact = 10

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Which band `score` came from.
    static func kind(of score: Int) -> Kind { Kind(rawValue: score / 10_000) ?? .typo }

    private static func isWordStart(_ s: String, _ index: String.Index) -> Bool {
        if index == s.startIndex { return true }
        let before = s[s.index(before: index)]
        return !before.isLetter && !before.isNumber
    }

    /// Subsequence match with bonuses for consecutive hits and word boundaries, or nil when `q` isn't a subsequence of `c`.
    private static func subsequenceScore(_ q: [Character], _ c: [Character]) -> Int? {
        var qi = 0
        var score = 0
        var run = 0
        var prev = -2
        for (ci, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            var bonus = 1
            if ci == prev + 1 {
                run += 1
                bonus += run * 3
            } else {
                run = 0
            }
            if ci == 0 {
                bonus += 12
            } else {
                let before = c[ci - 1]
                if !before.isLetter && !before.isNumber { bonus += 8 }
            }
            score += bonus
            prev = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score
    }

    // MARK: - Typo tolerance

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
        // The DP is O(query × candidate) per word start; names are short, but guard the pathological case.
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
    private static func prefixDistance(_ q: [Character], _ c: [Character], from: Int, allowed: Int)
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
}
