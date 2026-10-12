import Foundation

/// The Applications grid's filters: Spotlight's own families, each several App Store categories.
enum AppCategory: String, CaseIterable, Identifiable, Sendable {
    case utilities
    case developerTools
    case productivityAndFinance
    case creativity
    case social
    case entertainment
    case healthAndFitness
    case informationAndReading
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utilities: "Utilities"
        case .developerTools: "Developer Tools"
        case .productivityAndFinance: "Productivity & Finance"
        case .creativity: "Creativity"
        case .social: "Social"
        case .entertainment: "Entertainment"
        case .healthAndFitness: "Health & Fitness"
        case .informationAndReading: "Information & Reading"
        case .other: "Other"
        }
    }

    private static let prefix = "public.app-category."

    /// A bundle's `LSApplicationCategoryType`; an app that declares none, or one unknown, is Other.
    init(declared: String?) {
        guard let declared, declared.hasPrefix(Self.prefix) else {
            self = .other
            return
        }
        let name = declared.dropFirst(Self.prefix.count)
        // Every game genre is `games.<genre>`, and none of them is its own chip.
        if name == "games" || name.hasPrefix("games.") {
            self = .entertainment
            return
        }
        switch name {
        case "utilities": self = .utilities
        case "developer-tools": self = .developerTools
        case "business", "productivity", "finance": self = .productivityAndFinance
        case "graphics-design", "photography", "video", "music": self = .creativity
        case "social-networking": self = .social
        case "entertainment", "sports": self = .entertainment
        case "healthcare-fitness", "medical": self = .healthAndFitness
        case "news", "reference", "education", "weather", "books": self = .informationAndReading
        default: self = .other
        }
    }
}
