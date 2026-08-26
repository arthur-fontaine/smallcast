import Foundation

@main
@MainActor
struct FallbackTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        roundTripsIDs()
        namesBuiltIns()
        filtersByAvailability()
        keepsTheUsersOrder()
        offersCandidates()
        buildsWebURLs()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static let quicklink = UUID(uuidString: "5C3B4A2E-0000-4000-8000-000000000001")!

    private static func availability(
        ai: Bool = true, files: Bool = true, quicklinks: Set<UUID> = []
    ) -> FallbackCommands.Availability {
        FallbackCommands.Availability(
            aiEnabled: ai, fileSearchEnabled: files, argumentQuicklinkIDs: quicklinks)
    }

    static func roundTripsIDs() {
        let all: [FallbackCommandID] = [.askAI, .searchWeb, .searchFiles, .quicklink(quicklink)]
        for id in all {
            expect(
                FallbackCommandID(rawValue: id.rawValue) == id,
                "\(id.rawValue) survives the stored spelling")
        }
        expect(
            Set(all.map(\.rawValue)).count == all.count, "no two fallbacks share a stored spelling")
        expect(FallbackCommandID(rawValue: "nonsense") == nil, "an unknown row is dropped")
        expect(
            FallbackCommandID(rawValue: "quicklink:not-a-uuid") == nil,
            "a quicklink row without a real id is dropped")
        expect(
            FallbackCommands.decode(["search-web", "junk", "search-files"])
                == [.searchWeb, .searchFiles],
            "decoding skips what it can't resolve rather than failing the list")
        expect(
            FallbackCommands.encode([.searchWeb, .askAI]) == ["search-web", "ask-ai"],
            "encoding is the same spelling, in order")
    }

    static func namesBuiltIns() {
        expect(
            FallbackCommandID.builtIns.allSatisfy { $0.builtInName != nil },
            "every built-in names itself")
        expect(
            FallbackCommandID.quicklink(quicklink).builtInName == nil,
            "a quicklink's name lives in its own record, not here")
        expect(
            FallbackCommandID.builtIns.allSatisfy { !$0.sfSymbol.isEmpty },
            "every fallback has a glyph to draw")
        expect(
            FallbackCommands.defaults == [.searchWeb, .searchFiles],
            "Ask AI ships unlisted: it already has a chord of its own")
    }

    static func filtersByAvailability() {
        let stored: [FallbackCommandID] = [.askAI, .searchFiles, .searchWeb, .quicklink(quicklink)]
        expect(
            FallbackCommands.resolved(stored: stored, availability: availability(ai: false))
                == [.searchFiles, .searchWeb],
            "AI off drops Ask AI, and an unknown quicklink drops with it")
        expect(
            FallbackCommands.resolved(stored: stored, availability: availability(files: false))
                == [.askAI, .searchWeb],
            "File Search off drops its row")
        expect(
            FallbackCommands.resolved(
                stored: stored, availability: availability(quicklinks: [quicklink]))
                == stored,
            "a quicklink that takes an argument stays")
        expect(
            FallbackCommands.resolved(stored: [], availability: availability()).isEmpty,
            "an emptied list offers nothing — no silent fallback to the defaults")
    }

    static func keepsTheUsersOrder() {
        expect(
            FallbackCommands.resolved(
                stored: [.searchFiles, .searchWeb, .askAI], availability: availability())
                == [.searchFiles, .searchWeb, .askAI],
            "the stored order is the row order")
        expect(
            FallbackCommands.resolved(
                stored: [.searchWeb, .searchWeb, .searchFiles], availability: availability())
                == [.searchWeb, .searchFiles],
            "a duplicate keeps its first position and appears once")
    }

    static func offersCandidates() {
        let candidates = FallbackCommands.candidates(
            stored: [.searchWeb], availability: availability(quicklinks: [quicklink]),
            quicklinkIDs: [quicklink])
        expect(!candidates.contains(.searchWeb), "what is already listed is not offered again")
        expect(candidates.contains(.askAI), "an unlisted built-in is offered")
        expect(candidates.contains(.quicklink(quicklink)), "so is an argument-taking quicklink")
        expect(
            !FallbackCommands.candidates(
                stored: [], availability: availability(ai: false), quicklinkIDs: [])
                .contains(.askAI),
            "a disabled feature is never offered")
    }

    static func buildsWebURLs() {
        expect(
            FallbackCommands.webURL(template: FallbackCommands.defaultWebTemplate, query: "swift 6")?
                .absoluteString == "https://duckduckgo.com/?q=swift%206",
            "the query is percent-encoded into the template")
        expect(
            FallbackCommands.webURL(template: "https://x.dev/?q={query}", query: "a&b=c/d?e")?
                .absoluteString == "https://x.dev/?q=a%26b%3Dc%2Fd%3Fe",
            "every reserved character is encoded, so it can't rewrite the URL")
        expect(
            FallbackCommands.webURL(template: "https://x.dev/", query: "q") == nil,
            "a template with no placeholder cannot carry a query, so it is unusable")
        expect(
            FallbackCommands.webURL(template: "  https://x.dev/?q={query}  ", query: "q") != nil,
            "a pasted template is trimmed")
    }
}
