import Foundation

struct FileSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let parentPath: String
    /// The enclosing folder's own name, which is what tells two same-named folders apart.
    let parentName: String
    let isDirectory: Bool
    /// DigUp's matching passage: why a file whose name says nothing of the query is here.
    let excerpt: String?

    /// `url` is taken as given: index paths are already real, and standardizing one costs a stat.
    init(url: URL, isDirectory: Bool, homeDirectory: URL, excerpt: String? = nil) {
        let parent = url.deletingLastPathComponent()
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.parentPath = Self.abbreviate(
            parent.path, homePath: homeDirectory.path)
        self.parentName = parent.lastPathComponent
        self.isDirectory = isDirectory
        self.excerpt = excerpt
    }

    private static func abbreviate(_ path: String, homePath: String) -> String {
        if path == homePath { return "~" }
        guard path.hasPrefix(homePath + "/") else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
