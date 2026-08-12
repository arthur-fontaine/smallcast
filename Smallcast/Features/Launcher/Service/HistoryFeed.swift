import Foundation

/// One row of the Recent list: something launched, or a calculation.
enum HistoryItem: Identifiable, Equatable, Sendable {
    case entry(AppEntry, usedAt: Date)
    case calculation(CalcHistoryEntry)

    var id: String {
        switch self {
        case .entry(let app, _): return "entry:" + app.id
        case .calculation(let entry): return "calc:" + entry.id.uuidString
        }
    }

    /// When it happened — the only thing that orders the feed.
    var date: Date {
        switch self {
        case .entry(_, let usedAt): return usedAt
        case .calculation(let entry): return entry.createdAt
        }
    }
}

/// Builds the Recent list the palette shows on ↑: launches and calculations interleaved, newest
/// first. Deliberately chronological rather than ranked — this is "what did I just do", while the
/// launcher's own results are "what am I looking for".
enum HistoryFeed {
    /// Deep enough to scroll through a few days, short enough to stay a keyboard list.
    static let limit = 100

    static func build(
        launches: [String: LaunchRecord], apps: [AppEntry], calculations: [CalcHistoryEntry],
        query: String
    ) -> [HistoryItem] {
        let byKey = Dictionary(
            apps.map { ($0.preferenceKey, $0) }, uniquingKeysWith: { first, _ in first })
        // An app since uninstalled, or a command from a disabled feature, simply drops out.
        var items = launches.compactMap { key, record -> HistoryItem? in
            guard let app = byKey[key] else { return nil }
            return .entry(app, usedAt: record.lastUsed)
        }
        items += calculations.map(HistoryItem.calculation)

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { items = items.filter { matches(trimmed, $0) } }
        return Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// The launcher's own matcher for entries (typos and categories included), so the two screens
    /// agree on what a query means; a calculation matches on either side of the "=".
    private static func matches(_ query: String, _ item: HistoryItem) -> Bool {
        switch item {
        case .entry(let app, _):
            return SearchRelevance.score(query: query, fields: app.searchFields) != nil
        case .calculation(let entry):
            return entry.expression.localizedCaseInsensitiveContains(query)
                || entry.result.localizedCaseInsensitiveContains(query)
        }
    }
}
