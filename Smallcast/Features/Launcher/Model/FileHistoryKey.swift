import Foundation

/// A file lives in `LaunchHistoryStore` beside the entries, under a key no entry can have.
extension FileSearchResult {
    private static let fileKeyPrefix = "file:"
    private static let folderKeyPrefix = "folder:"

    var historyKey: String { (isDirectory ? Self.folderKeyPrefix : Self.fileKeyPrefix) + id }

    init?(historyKey key: String, homeDirectory: URL) {
        let isDirectory = key.hasPrefix(Self.folderKeyPrefix)
        guard isDirectory || key.hasPrefix(Self.fileKeyPrefix) else { return nil }
        let path = String(key.dropFirst(isDirectory ? Self.folderKeyPrefix.count : Self.fileKeyPrefix.count))
        guard path.hasPrefix("/") else { return nil }
        self.init(
            url: URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            isDirectory: isDirectory, homeDirectory: homeDirectory)
    }
}
