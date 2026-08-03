import Foundation

/// How often and how recently one launcher entry was used.
struct UsageRecord: Codable, Equatable, Sendable {
    var count: Int
    var lastUsed: Date
}

/// Frecency: how much a past-usage record should lift an entry in the ranking. Foundation-only and
/// pure so `Tools/fuzz-test.swift` compiles the real thing.
enum UsageScore {
    /// Recency multiplier applied to the launch count. Decaying it this steeply is what keeps a
    /// long-dormant entry from sitting at the top forever, while the count is what lets a habit
    /// outrank something opened once this morning.
    static func weight(age: TimeInterval) -> Int {
        switch age {
        case ..<3600: return 100  // within the hour
        case ..<86_400: return 60  // today
        case ..<604_800: return 30  // this week
        case ..<2_592_000: return 12  // this month
        default: return 4
        }
    }

    /// A single comparable number. The count is capped so a decade of Safari launches can't bury
    /// everything else — past ~25 uses an entry is a habit, and recency decides between habits.
    static func score(_ record: UsageRecord, now: Date) -> Int {
        let age = max(0, now.timeIntervalSince(record.lastUsed))
        return min(record.count, 25) * weight(age: age)
    }
}

/// Remembers what the user launches, which drives two things: the ranking tiebreak inside each match
/// tier (most-used first), and the Recent list the palette shows on ↑.
///
/// Keyed like `FavoritesStore` — bundle id when there is one, entry id otherwise — and persisted next
/// to the other histories in `~/Library/Caches/<bundle-id>/` so `brew uninstall --zap` clears it.
@MainActor
final class UsageStore: ObservableObject {
    /// Enough for the Recent list plus a long ranking memory; the oldest fall off.
    private static let cap = 400

    private let fileURL: URL

    @Published private(set) var records: [String: UsageRecord]

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.smallcast.app"
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("usage.json")

        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: UsageRecord].self, from: data)
        {
            records = decoded
        } else {
            records = [:]
        }
    }

    func record(key: String, now: Date = Date()) {
        var record = records[key] ?? UsageRecord(count: 0, lastUsed: now)
        record.count += 1
        record.lastUsed = now
        records[key] = record
        prune()
        persist()
    }

    /// Ranking tiebreak for `key` — 0 for something never launched.
    func score(for key: String, now: Date = Date()) -> Int {
        guard let record = records[key] else { return 0 }
        return UsageScore.score(record, now: now)
    }

    func lastUsed(_ key: String) -> Date? { records[key]?.lastUsed }

    /// Keys newest-first — the order the Recent list is built in.
    var recentKeys: [String] {
        records.sorted { $0.value.lastUsed > $1.value.lastUsed }.map(\.key)
    }

    func forget(key: String) {
        guard records.removeValue(forKey: key) != nil else { return }
        persist()
    }

    func clearAll() {
        guard !records.isEmpty else { return }
        records = [:]
        persist()
    }

    private func prune() {
        guard records.count > Self.cap else { return }
        for key in recentKeys.dropFirst(Self.cap) { records.removeValue(forKey: key) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
