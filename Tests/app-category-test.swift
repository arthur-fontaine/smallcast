import Foundation

/// A bundle's declared App Store category lands on one of Spotlight's chips, and nothing is lost.
@main
struct AppCategoryTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func expect(_ declared: String?, _ expected: AppCategory, _ message: String) {
        let actual = AppCategory(declared: declared)
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message) — got \(actual), want \(expected)")
        }
    }

    static func main() {
        expect("public.app-category.utilities", .utilities, "Utilities is its own chip")
        expect("public.app-category.developer-tools", .developerTools, "so are Developer Tools")
        expect("public.app-category.finance", .productivityAndFinance, "finance joins productivity")
        expect("public.app-category.business", .productivityAndFinance, "so does business")
        expect("public.app-category.photography", .creativity, "photography is creative work")
        expect("public.app-category.games", .entertainment, "bare games are entertainment")
        expect("public.app-category.puzzle-games", .other, "an unknown name is Other, not a crash")
        expect("public.app-category.games.puzzle", .entertainment, "every game genre is too")
        expect("public.app-category.medical", .healthAndFitness, "medical joins health")
        expect("public.app-category.news", .informationAndReading, "news is reading")
        expect(nil, .other, "an app declaring nothing is Other")
        expect("com.example.category", .other, "a foreign identifier is Other")

        print("\n\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
