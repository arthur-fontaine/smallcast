import AppKit

/// Finds the helper DigUp.app ships, and where DigUp keeps its data.
enum DigUpLocator {
    static let bundleIdentifier = "com.abdurrahim.DigUp"
    static let downloadURL = URL(string: "https://github.com/ARahim3/DigUp/releases/latest")!
    private static let helperSubpath = "Contents/Helpers/digup"

    enum Availability: Equatable, Sendable {
        case found(URL)
        case notInstalled
        /// The path typed in Settings names nothing that can run.
        case missingCustomPath(String)
    }

    /// A typed path wins, so a build from source can stand in for the app's own helper.
    static func locate(customPath: String) -> Availability {
        let custom = customPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return isExecutable(path) ? .found(URL(fileURLWithPath: path)) : .missingCustomPath(custom)
        }
        let candidates =
            [NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)]
            + [URL(fileURLWithPath: "/Applications/DigUp.app"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/DigUp.app")]
        for app in candidates.compactMap({ $0 }) {
            let helper = app.appendingPathComponent(helperSubpath)
            if isExecutable(helper.path) { return .found(helper) }
        }
        return .notInstalled
    }

    /// A moved index or model folder lives in DigUp's defaults, which its helper never reads.
    static func dataDirectories() -> (index: String?, models: String?) {
        let defaults = UserDefaults(suiteName: bundleIdentifier)
        return (defaults?.string(forKey: "indexDir"), defaults?.string(forKey: "modelsDir"))
    }

    /// Read, never written: these are DigUp's settings, and its app is where they change.
    static func folders() -> DigUpFolders {
        let defaults = UserDefaults(suiteName: bundleIdentifier)
        return DigUpFolders(
            roots: defaults?.stringArray(forKey: "roots") ?? [],
            skipped: defaults?.stringArray(forKey: "excludedFolders") ?? [],
            types: defaults?.stringArray(forKey: "excludedTypes") ?? [])
    }

    /// When DigUp last wrote its index, so a searcher opened before that can reload it.
    static func indexModified(indexDirectory: String?) -> Date? {
        let directory =
            indexDirectory.map { ($0 as NSString).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DigUp/index.noindex").path
        // SQLite's write-ahead log changes on every commit; the database file only on a checkpoint.
        return ["index.sqlite", "index.sqlite-wal"].compactMap { name in
            try? FileManager.default.attributesOfItem(atPath: directory + "/" + name)[.modificationDate]
                as? Date
        }.max()
    }

    /// DigUp's onboarding records its folders here; until then its index holds nothing to find.
    static func isSetUp() -> Bool {
        let defaults = UserDefaults(suiteName: bundleIdentifier)
        return defaults?.bool(forKey: "onboarded") == true
            || defaults?.stringArray(forKey: "roots")?.isEmpty == false
    }

    /// The app around a helper it ships; nil for a helper built from source.
    static func app(containing helper: URL) -> URL? {
        let app = helper.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
