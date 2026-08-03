// Standalone test for the launcher matcher and the usage (frecency) scoring — compiles the *real*
// Foundation-only sources (no copy to sync):
// swiftc Smallcast/Core/{FuzzyMatch,UsageStore}.swift Tools/fuzz-test.swift -o /tmp/fuzz-test && /tmp/fuzz-test

import Foundation

@main
struct FuzzTests {
    static let apps = [
        "Google Chrome", "Chess", "Time Machine", "Safari", "Bluetooth File Exchange",
        "Screenshot", "Screen Sharing", "Visual Studio Code", "Photos", "App Store",
        "System Settings", "Calendar", "Terminal",
    ]

    static var failures = 0

    static func main() {
        let chrome = rank("chrome")
        check("'chrome' top is Google Chrome", chrome.first == "Google Chrome", "got \(chrome)")
        check("'chrome' does not include Chess", !chrome.contains("Chess"), "got \(chrome)")

        let ch = rank("ch")
        check("'ch' includes Google Chrome", ch.contains("Google Chrome"), "got \(ch)")
        check("'ch' includes Chess", ch.contains("Chess"))
        check(
            "'ch' ranks Chess (prefix) above Chrome",
            ch.firstIndex(of: "Chess")! < ch.firstIndex(of: "Google Chrome")!, "got \(ch)")

        check("'saf' top is Safari", rank("saf").first == "Safari", "got \(rank("saf"))")
        check("'tm' includes Time Machine", rank("tm").contains("Time Machine"), "got \(rank("tm"))")
        check(
            "'code' includes Visual Studio Code", rank("code").contains("Visual Studio Code"),
            "got \(rank("code"))")
        check("'terminal' exact top", rank("terminal").first == "Terminal")
        check("'xyz' matches nothing", rank("xyz").isEmpty, "got \(rank("xyz"))")

        // Typo tolerance — a near-miss still finds the app
        check("'safri' finds Safari", rank("safri").first == "Safari", "got \(rank("safri"))")
        check("'chorme' finds Chrome", rank("chorme").first == "Google Chrome", "got \(rank("chorme"))")
        check("'terminl' finds Terminal", rank("terminl").first == "Terminal", "got \(rank("terminl"))")
        check(
            "'calender' finds Calendar", rank("calender").first == "Calendar",
            "got \(rank("calender"))")
        check(
            "'sytem settings' finds System Settings", rank("sytem settings").first == "System Settings",
            "got \(rank("sytem settings"))")
        check(
            "'screan sharing' finds Screen Sharing", rank("screan sharing").first == "Screen Sharing",
            "got \(rank("screan sharing"))")
        // A typo inside a later word still resolves — word starts are tried too
        check(
            "'machne' finds Time Machine", rank("machne").contains("Time Machine"),
            "got \(rank("machne"))")
        // Short queries get no slack: three characters are within one edit of almost anything
        check("'qzt' matches nothing", rank("qzt").isEmpty, "got \(rank("qzt"))")
        check("'zzzzzz' matches nothing", rank("zzzzzz").isEmpty, "got \(rank("zzzzzz"))")

        // Tiers: a real match always outranks a typo match, whatever the tiebreak
        let exact = FuzzyMatch.score(query: "chess", candidate: "Chess")!
        let prefix = FuzzyMatch.score(query: "chess", candidate: "Chessboard")!
        let subsequence = FuzzyMatch.score(query: "tm", candidate: "Time Machine")!
        let typo = FuzzyMatch.score(query: "chees", candidate: "Chess")!
        check("exact > prefix", FuzzyMatch.kind(of: exact) > FuzzyMatch.kind(of: prefix))
        check("prefix > subsequence", FuzzyMatch.kind(of: prefix) > FuzzyMatch.kind(of: subsequence))
        check("subsequence > typo", FuzzyMatch.kind(of: subsequence) > FuzzyMatch.kind(of: typo))
        check("a typo scores as a typo", FuzzyMatch.kind(of: typo) == .typo)
        // Category search leans on these: a mid-word substring must stay distinguishable from a
        // word-start one, or "cat" would list every Appli*cat*ion.
        check(
            "mid-word substring is its own kind",
            FuzzyMatch.kind(of: FuzzyMatch.score(query: "cat", candidate: "Application")!)
                == .substring)
        check(
            "word-start substring outranks it",
            FuzzyMatch.kind(of: FuzzyMatch.score(query: "management", candidate: "Window Management")!)
                == .wordStart)
        check(
            "'windwo' is a typo of the Window Management category",
            FuzzyMatch.kind(of: FuzzyMatch.score(query: "windwo", candidate: "Window Management")!)
                == .typo)
        check(
            "no slack under four characters", FuzzyMatch.allowedDistance(forQueryLength: 3) == 0)

        // Frecency: recency dominates, count only scales what's left, and both are capped
        let now = Date()
        let today = UsageRecord(count: 2, lastUsed: now.addingTimeInterval(-1800))
        let onceLastMonth = UsageRecord(count: 2, lastUsed: now.addingTimeInterval(-20 * 86_400))
        check(
            "same count, more recent wins",
            UsageScore.score(today, now: now) > UsageScore.score(onceLastMonth, now: now),
            "\(UsageScore.score(today, now: now)) vs \(UsageScore.score(onceLastMonth, now: now))")
        let staple = UsageRecord(count: 40, lastUsed: now.addingTimeInterval(-20 * 86_400))
        let oneOff = UsageRecord(count: 1, lastUsed: now.addingTimeInterval(-3 * 3600))
        check(
            "a habit outranks something opened once today",
            UsageScore.score(staple, now: now) > UsageScore.score(oneOff, now: now),
            "\(UsageScore.score(staple, now: now)) vs \(UsageScore.score(oneOff, now: now))")
        let onceToday = UsageRecord(count: 1, lastUsed: now.addingTimeInterval(-1800))
        check(
            "more launches rank higher at equal recency",
            UsageScore.score(today, now: now) > UsageScore.score(onceToday, now: now))
        let ancient = UsageRecord(count: 3, lastUsed: now.addingTimeInterval(-400 * 86_400))
        check(
            "a stale record still outranks an unused one", UsageScore.score(ancient, now: now) > 0)
        check(
            "count is capped",
            UsageScore.score(UsageRecord(count: 25, lastUsed: now), now: now)
                == UsageScore.score(UsageRecord(count: 9_000, lastUsed: now), now: now))

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func rank(_ query: String) -> [String] {
        apps.compactMap { name -> (String, Int)? in
            guard let s = FuzzyMatch.score(query: query, candidate: name) else { return nil }
            return (name, s)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }
        .map(\.0)
    }

    static func check(_ desc: String, _ cond: Bool, _ detail: String = "") {
        if cond {
            print("PASS  \(desc)")
        } else {
            print("FAIL  \(desc)  \(detail)")
            failures += 1
        }
    }
}
