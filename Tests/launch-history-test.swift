import Foundation

/// Guards `LaunchHistoryStore`: the per-entry recency the Recent list and Settings › Search read.
/// Every clock read is injected, so nothing here waits on wall time.
@main
@MainActor
struct LaunchHistoryTests {
    static var failures = 0
    static var passes = 0

    static let day: TimeInterval = 86_400

    static func main() {
        recording()
        forgetting()
        windowedReset()
        eviction()
        persistence()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Recording

    static func recording() {
        print("\n# recording")
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = make { clock }

        store.record(itemKey: "com.apple.Safari")
        check("a first launch is counted", store.count(itemKey: "com.apple.Safari") == 1)
        check("and stamped", store.lastUsed(itemKey: "com.apple.Safari") == clock)

        clock += day
        store.record(itemKey: "com.apple.Safari")
        check("a repeat increments", store.count(itemKey: "com.apple.Safari") == 2)
        check("and re-stamps", store.lastUsed(itemKey: "com.apple.Safari") == clock)

        store.record(itemKey: "")
        check("an empty key is ignored", store.records.count == 1)
        check("an unknown key has no date", store.lastUsed(itemKey: "nope") == nil)
        check("and no count", store.count(itemKey: "nope") == 0)
    }

    // MARK: - Forgetting one entry

    static func forgetting() {
        print("\n# forgetting")
        let store = make { Date(timeIntervalSince1970: 1_000_000) }
        store.record(itemKey: "a")
        store.record(itemKey: "b")

        let before = store.revision
        store.reset(itemKey: "a")
        check("the entry is gone", store.lastUsed(itemKey: "a") == nil)
        check("its neighbour is not", store.lastUsed(itemKey: "b") != nil)
        check("and the revision moved", store.revision != before)

        let unchanged = store.revision
        store.reset(itemKey: "a")
        check("forgetting nothing does not bump the revision", store.revision == unchanged)
    }

    // MARK: - Windowed reset

    static func windowedReset() {
        print("\n# windowed reset")
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = make { clock }

        store.record(itemKey: "old")
        clock += 30 * day
        store.record(itemKey: "recent")
        let now = clock

        store.reset(since: now.addingTimeInterval(-7 * day))
        check("what happened inside the window is forgotten", store.lastUsed(itemKey: "recent") == nil)
        check("what happened before it is kept", store.lastUsed(itemKey: "old") != nil)

        store.reset(since: nil)
        check("a nil cutoff clears everything", store.isEmpty)

        let quiet = store.revision
        store.reset(since: nil)
        check("clearing an empty table does not bump the revision", store.revision == quiet)
    }

    // MARK: - Eviction

    static func eviction() {
        print("\n# eviction")
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = make { clock }

        // 600 entries, oldest first, against a 500 cap.
        for index in 0..<600 {
            store.record(itemKey: "item-\(index)")
            clock += 60
        }
        check("the table stays capped", store.records.count == 500)
        check("the oldest went first", store.lastUsed(itemKey: "item-0") == nil)
        check("the newest stayed", store.lastUsed(itemKey: "item-599") != nil)
        // Recency, not frequency: a heavily-used but stale entry is still the one to drop.
        check("the cutoff is by last use", store.lastUsed(itemKey: "item-99") == nil)
        check("and everything after it survives", store.lastUsed(itemKey: "item-100") != nil)
    }

    // MARK: - Persistence

    static func persistence() {
        print("\n# persistence")
        let url = temporaryURL()
        let clock = Date(timeIntervalSince1970: 1_000_000)
        let store = LaunchHistoryStore(fileURL: url, now: { clock })
        store.record(itemKey: "com.apple.Terminal")

        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await store.flush()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        let reloaded = LaunchHistoryStore(fileURL: url, now: { clock })
        check("a launch survives a reload", reloaded.count(itemKey: "com.apple.Terminal") == 1)
        check("with its timestamp", reloaded.lastUsed(itemKey: "com.apple.Terminal") == clock)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    static func make(_ now: @escaping () -> Date) -> LaunchHistoryStore {
        LaunchHistoryStore(fileURL: temporaryURL(), now: now)
    }

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-history-\(UUID().uuidString).json")
    }

    static func check(_ description: String, _ condition: Bool) {
        if condition {
            passes += 1
            print("PASS  \(description)")
        } else {
            failures += 1
            print("FAIL  \(description)")
        }
    }
}
