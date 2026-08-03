import Foundation

/// How often and how recently one launcher entry was used.
struct UsageRecord: Codable, Equatable, Sendable {
    /// Kept short: enough to date a window's worth of launches, not a full audit log.
    static let recentCap = 32

    var count: Int
    var lastUsed: Date
    /// Timestamps of the most recent launches, oldest first. This is what makes "forget today" exact —
    /// with only a total and a last-used date, a windowed reset could only guess.
    var recent: [Date] = []

    init(count: Int, lastUsed: Date, recent: [Date] = []) {
        self.count = count
        self.lastUsed = lastUsed
        self.recent = recent
    }

    /// Hand-written so records written before `recent` existed still decode (they simply carry no
    /// timestamps, and a windowed reset falls back to dropping them whole).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)
        lastUsed = try container.decode(Date.self, forKey: .lastUsed)
        recent = try container.decodeIfPresent([Date].self, forKey: .recent) ?? []
    }

    mutating func launched(at now: Date) {
        count += 1
        lastUsed = now
        recent.append(now)
        if recent.count > Self.recentCap { recent.removeFirst(recent.count - Self.recentCap) }
    }

    /// This record with everything from `cutoff` onwards forgotten, or nil when nothing is left of it.
    /// Launches older than the timestamps we kept are preserved, so resetting "today" doesn't wipe a
    /// habit built up over months.
    func cleared(since cutoff: Date) -> UsageRecord? {
        guard lastUsed >= cutoff else { return self }
        let kept = recent.filter { $0 < cutoff }
        // Nothing dated survives and the only date we have falls inside the window: drop the record.
        guard let newest = kept.last else { return nil }
        let forgotten = recent.count - kept.count
        let count = max(0, self.count - forgotten)
        guard count > 0 else { return nil }
        return UsageRecord(count: count, lastUsed: newest, recent: kept)
    }

    /// How many of the remembered launches happened at or after `date` — the "3 today" in Settings.
    func launches(since date: Date) -> Int {
        recent.filter { $0 >= date }.count
    }
}

/// How far back a usage reset reaches. "Today" is the one people actually mean by "reset this
/// morning"; the rest bracket it.
enum UsageResetRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour
    case today
    case lastWeek
    case lastMonth
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastHour: return "The last hour"
        case .today: return "Today"
        case .lastWeek: return "The last 7 days"
        case .lastMonth: return "The last 30 days"
        case .everything: return "Everything"
        }
    }

    /// Launches at or after this instant are forgotten; nil means the whole history goes.
    func cutoff(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .lastHour: return now.addingTimeInterval(-3600)
        case .today: return calendar.startOfDay(for: now)
        case .lastWeek: return now.addingTimeInterval(-7 * 86_400)
        case .lastMonth: return now.addingTimeInterval(-30 * 86_400)
        case .everything: return nil
        }
    }
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
        record.launched(at: now)
        records[key] = record
        prune()
        persist()
    }

    /// Forget everything learned since `range` began. Records that predate it keep their older
    /// launches, so "reset today" undoes a morning's worth of ranking rather than months of it.
    func reset(_ range: UsageResetRange, now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = range.cutoff(now: now, calendar: calendar) else {
            clearAll()
            return
        }
        let updated = records.compactMapValues { $0.cleared(since: cutoff) }
        guard updated != records else { return }
        records = updated
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
