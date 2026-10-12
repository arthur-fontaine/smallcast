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

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
