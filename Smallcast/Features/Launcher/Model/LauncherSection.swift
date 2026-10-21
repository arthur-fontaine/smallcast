import Foundation

/// Root search's blocks below its lead card, in the order Settings › Search gives them.
enum LauncherSection: String, CaseIterable, Sendable {
    case results
    case files
    case fallbacks

    static let defaultOrder: [LauncherSection] = allCases

    var title: String {
        switch self {
        case .results: return String(localized: "Results")
        case .files: return String(localized: "Files")
        case .fallbacks: return String(localized: "Fallbacks")
        }
    }

    var symbol: String {
        switch self {
        case .results: return "square.grid.2x2"
        case .files: return "doc"
        case .fallbacks: return "arrow.turn.down.right"
        }
    }

    /// Each section exactly once; one a stored list lacks keeps its default place at the end.
    static func normalize(_ order: [LauncherSection]) -> [LauncherSection] {
        var seen = Set<LauncherSection>()
        let kept = order.filter { seen.insert($0).inserted }
        return kept + allCases.filter { !seen.contains($0) }
    }

    /// The rows before `section` once `lead` leading rows are drawn, given each section's row count.
    static func start(
        of section: LauncherSection, in order: [LauncherSection], lead: Int,
        count: (LauncherSection) -> Int
    ) -> Int {
        lead + order.prefix { $0 != section }.reduce(0) { $0 + count($1) }
    }
}
