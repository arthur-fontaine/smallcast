// The fallback list's pure half: identity, stored order, the header's elision and preset filling.

import Foundation

@main
@MainActor
struct FallbackTests {
    static var failures = 0
    static var passes = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    static func main() {
        identity()
        ordering()
        headers()
        verbs()
        presetFilling()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Identity

    static func identity() {
        // The id *is* the row's entry id, which is what lets a stored order name a live row.
        for builtin in Fallback.Builtin.allCases {
            let fallback = Fallback.builtin(builtin)
            check(
                "\(builtin.rawValue) is its command's id", fallback.id == builtin.command.rawValue,
                "got \(fallback.id)")
            check(
                "\(builtin.rawValue) round-trips", Fallback(id: fallback.id) == fallback,
                "got \(String(describing: Fallback(id: fallback.id)))")
        }

        let quicklinkID = UUID()
        let quicklink = Fallback.quicklink(quicklinkID)
        check(
            "a quicklink's id is its entry id",
            quicklink.id == Quicklink.entryIDPrefix + quicklinkID.uuidString.lowercased(),
            "got \(quicklink.id)")
        check("a quicklink round-trips", Fallback(id: quicklink.id) == quicklink)

        let prompt = Fallback.quickPrompt(UUID())
        check(
            "a quick prompt's id is its entry id",
            prompt.id.hasPrefix(QuickPrompt.entryIDPrefix), "got \(prompt.id)")
        check("a quick prompt round-trips", Fallback(id: prompt.id) == prompt)

        // A preset over a quicklink must not collide with that quicklink's own row.
        let preset = Fallback.preset(quicklinkID)
        check("a preset round-trips", Fallback(id: preset.id) == preset)
        check("a preset is not its target's row", preset.id != quicklink.id)

        // Every built-in's id must be distinct, or one would silently take another's stored slot.
        let ids = Set(Fallback.Builtin.allCases.map { Fallback.builtin($0).id })
        check("built-in ids are distinct", ids.count == Fallback.Builtin.allCases.count)

        // A command with no fallback of its own must not resolve to one.
        check("a plain command is not a fallback", Fallback(id: CommandID.about.rawValue) == nil)
        check("nonsense is not a fallback", Fallback(id: "banana") == nil)
        check("a bare uuid is not a fallback", Fallback(id: UUID().uuidString) == nil)
    }

    // MARK: - Ordering

    static func ordering() {
        let ai = Fallback.builtin(.quickAI)
        let files = Fallback.builtin(.searchFiles)
        let shell = Fallback.builtin(.runShellCommand)
        let link = Fallback.quicklink(UUID())

        check(
            "no stored order keeps the offered order",
            Fallback.ordered([ai, files, shell], by: []) == [ai, files, shell])

        check(
            "a stored order is honoured",
            Fallback.ordered([ai, files, shell], by: [shell.id, ai.id, files.id])
                == [shell, ai, files])

        // A quicklink created after the last reorder must land at the end, not vanish.
        check(
            "an unseen fallback lands last",
            Fallback.ordered([ai, link, files], by: [files.id, ai.id]) == [files, ai, link])

        // A deleted quicklink's id is still stored; it must not resurrect or shift its neighbours.
        check(
            "a stored id with nothing behind it is skipped",
            Fallback.ordered([ai, files], by: [link.id, files.id, ai.id]) == [files, ai])

        check("nothing available is nothing offered", Fallback.ordered([], by: [ai.id]).isEmpty)
    }

    // MARK: - Header

    static func headers() {
        check(
            "a short query is quoted whole",
            Fallback.sectionTitle(query: "todo") == "Use “todo” with…",
            "got \(Fallback.sectionTitle(query: "todo"))")

        let long = String(repeating: "a", count: 200)
        let title = Fallback.sectionTitle(query: long, limit: 20)
        // The point of the elision: the header must still say what the section is for.
        check("a long query still ends in the verb", title.hasSuffix("” with…"), "got \(title)")
        check("a long query is elided", title.contains("…a"), "got \(title)")
        check("a long query is bounded by the limit", title.count <= 20 + 13, "got \(title.count)")

        // The boundary is exact equality, so a query at the limit is never touched.
        let exact = String(repeating: "b", count: 20)
        check(
            "a query at the limit is kept whole",
            Fallback.sectionTitle(query: exact, limit: 20) == "Use “\(exact)” with…")

        // The shipped limit has to clear a real URL, which is the query this was drawn against.
        let url = "https://github.com/vgnshiyer/py-apple-books.git"
        check(
            "the default limit keeps a repository URL whole",
            Fallback.sectionTitle(query: url) == "Use “\(url)” with…",
            "got \(Fallback.sectionTitle(query: url))")
    }

    // MARK: - Verbs

    static func verbs() {
        var verbs = Fallback.Builtin.allCases.map { Fallback.builtin($0).openVerb }
        verbs.append(Fallback.quicklink(UUID()).openVerb)
        check("every fallback names its own action", verbs.allSatisfy { !$0.isEmpty })
        check("the verbs are distinct", Set(verbs).count == verbs.count, "got \(verbs)")
        check("a quick prompt says where it goes", !Fallback.quickPrompt(UUID()).openVerb.isEmpty)
    }

    // MARK: - Preset filling

    static func presetFilling() {
        let translate = SnippetTemplateEngine.declaredArguments(
            in: "Translate ~~~{argument name=\"text\"}~~~ to {argument name=\"language\"}")

        // The use case: a preset gives the language, so the query has to become the text.
        let english = FallbackPreset.values(
            filling: "bonjour", into: translate, given: ["language": "English"])
        check(
            "the query takes the argument the preset left open",
            english == ["text": "bonjour", "language": "English"], "got \(english)")

        let plain = FallbackPreset.values(filling: "bonjour", into: translate)
        check("with nothing given it takes the first", plain == ["text": "bonjour"], "got \(plain)")

        let reversed = FallbackPreset.values(
            filling: "French", into: translate, given: ["text": "hello"])
        check(
            "giving the first argument moves the query to the next",
            reversed == ["text": "hello", "language": "French"], "got \(reversed)")

        // An empty given value is no answer, so it stays open for the query.
        let blank = FallbackPreset.values(filling: "hi", into: translate, given: ["text": ""])
        check("a blank given value is open", blank["text"] == "hi", "got \(blank)")

        let all = FallbackPreset.values(
            filling: "ignored", into: translate, given: ["text": "a", "language": "b"])
        check(
            "with everything given the query is unused", all == ["text": "a", "language": "b"],
            "got \(all)")

        // An owed argument beats an optional one, as the quicklink fallback always did.
        let toned = SnippetTemplateEngine.declaredArguments(
            in: "{argument name=\"tone\" default=\"calm\"} {argument name=\"topic\"}")
        let topic = FallbackPreset.values(filling: "cats", into: toned)
        check("an owed argument is preferred", topic == ["topic": "cats"], "got \(topic)")

        let defaults = SnippetTemplateEngine.declaredArguments(
            in: "{argument name=\"a\" default=\"1\"} {argument name=\"b\" default=\"2\"}")
        check(
            "with only optional arguments the first takes it",
            FallbackPreset.values(filling: "x", into: defaults) == ["a": "x"])
        check("no argument takes nothing", FallbackPreset.values(filling: "x", into: []).isEmpty)
    }
}
