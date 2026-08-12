import Foundation

/// How far back "forget what you learned" reaches.
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
    func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .lastHour: return now.addingTimeInterval(-3600)
        case .today: return calendar.startOfDay(for: now)
        case .lastWeek: return now.addingTimeInterval(-7 * 86_400)
        case .lastMonth: return now.addingTimeInterval(-30 * 86_400)
        case .everything: return nil
        }
    }
}

/// How often an entry has been opened, and when it last was.
struct LaunchRecord: Codable, Hashable, Sendable {
    var count: Int
    var lastUsed: Date
}

/// Per-entry recency, kept apart from `LauncherRankingStore` because the two answer different
/// questions: ranking learns *which query meant which entry*, and only sees a launch that came from
/// typing. This sees every launch — a favorite, ⌘1, a hotkey — which is what "what did I just do"
/// needs. It is also the table Settings › Search shows and clears.
@MainActor
@Observable
final class LaunchHistoryStore {
    /// Deep enough for the Recent list plus a readable Settings table; the rest is noise.
    private static let cap = 500

    private let fileURL: URL
    private let now: () -> Date

    private(set) var records: [String: LaunchRecord]
    /// Bumped on every mutation, so a memoized result set names the table it was built from.
    private(set) var revision = 0

    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(fileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.now = now
        if let data = try? Data(contentsOf: self.fileURL),
            let decoded = try? JSONDecoder().decode([String: LaunchRecord].self, from: data)
        {
            records = decoded
        } else {
            records = [:]
        }
    }

    var isEmpty: Bool { records.isEmpty }

    /// Awaits the pending persist. The launcher never needs it; reading the file back does.
    func flush() async {
        await writeTask?.value
    }

    func record(itemKey: String) {
        guard !itemKey.isEmpty else { return }
        let timestamp = now()
        if var existing = records[itemKey] {
            existing.count += 1
            existing.lastUsed = timestamp
            records[itemKey] = existing
        } else {
            records[itemKey] = LaunchRecord(count: 1, lastUsed: timestamp)
        }
        if records.count > Self.cap {
            // Evict the least recently used, not the least frequent: this table is about recency.
            for key in records.sorted(by: { $0.value.lastUsed < $1.value.lastUsed })
                .prefix(records.count - Self.cap).map(\.key)
            {
                records.removeValue(forKey: key)
            }
        }
        didMutate()
    }

    func lastUsed(itemKey: String) -> Date? { records[itemKey]?.lastUsed }
    func count(itemKey: String) -> Int { records[itemKey]?.count ?? 0 }

    func reset(itemKey: String) {
        guard records.removeValue(forKey: itemKey) != nil else { return }
        didMutate()
    }

    /// Forgetting a window rather than everything: "the last hour", "today", "the last 7 days".
    /// A record whose whole run is inside the window goes; anything older keeps its earlier count,
    /// which cannot be reconstructed, so it keeps the count it has and loses only its recency claim.
    func reset(since cutoff: Date?) {
        guard let cutoff else {
            guard !records.isEmpty else { return }
            records = [:]
            didMutate()
            return
        }
        let stale = records.filter { $0.value.lastUsed >= cutoff }.map(\.key)
        guard !stale.isEmpty else { return }
        for key in stale { records.removeValue(forKey: key) }
        didMutate()
    }

    /// Beside `launcher-ranking.json`, in the same per-channel caches root.
    private static func defaultFileURL() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.smallcast.app"
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("launch-history.json")
    }

    private func didMutate() {
        revision &+= 1
        let snapshot = records
        let url = fileURL
        writeTask?.cancel()
        writeTask = Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
