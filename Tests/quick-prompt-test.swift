// Quick prompts' store: validation, display order, persistence and the backup replace.

import Foundation

@main
@MainActor
struct QuickPromptTests {
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

    static func freshDefaults() -> UserDefaults {
        let name = "quick-prompt-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func main() {
        validation()
        ordering()
        persistence()
        replacing()
        identity()
        connectingWords()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func validation() {
        let store = QuickPromptStore(defaults: freshDefaults())
        let added = try? store.add(
            QuickPrompt(name: "  Translate ", template: "\n Translate {argument name=\"text\"}\n"))
        check("a prompt is trimmed on the way in", added?.name == "Translate")
        check(
            "only the template's ends are trimmed",
            added?.template == "Translate {argument name=\"text\"}", "got \(String(describing: added))")

        func error(_ draft: QuickPrompt) -> QuickPromptError? {
            do {
                try store.add(draft)
                return nil
            } catch {
                return error
            }
        }
        check("a blank name is refused", error(QuickPrompt(name: " ", template: "x")) == .emptyName)
        check("a blank prompt is refused", error(QuickPrompt(name: "x", template: " ")) == .emptyTemplate)
        check(
            "a name is unique, whatever its case",
            error(QuickPrompt(name: "translate", template: "x")) == .duplicateName)
        check(
            "a null character is refused",
            error(QuickPrompt(name: "a\0b", template: "x")) == .invalidCharacter)
        check(
            "an empty icon means automatic",
            (try? store.add(QuickPrompt(name: "Icon", template: "x", iconSymbol: " ")))?.iconSymbol == nil)

        // Editing keeps its own name free: it is not a duplicate of itself.
        if var edited = added {
            edited.template = "Translate {argument name=\"text\"} to French"
            check("an edit keeps the same name", (try? store.update(edited)) != nil)
            check(
                "an edit lands", store.prompt(id: edited.id)?.template.hasSuffix("French") == true)
        }
        check(
            "the declared arguments are the launcher's fields",
            store.prompts.first { $0.name == "Translate" }?.arguments.map(\.name) == ["text"])
    }

    static func ordering() {
        let store = QuickPromptStore(defaults: freshDefaults())
        _ = try? store.add(QuickPrompt(name: "beta", template: "b"))
        _ = try? store.add(QuickPrompt(name: "Alpha", template: "a"))
        check("prompts list by name", store.prompts.map(\.name) == ["Alpha", "beta"])
    }

    static func persistence() {
        let defaults = freshDefaults()
        let store = QuickPromptStore(defaults: defaults)
        let prompt = try? store.add(QuickPrompt(name: "Summarize", template: "Summarize {clipboard}"))
        if let prompt { store.setEnabled(false, id: prompt.id) }
        if let prompt { store.setShowsInRootSearch(false, id: prompt.id) }
        let reloaded = QuickPromptStore(defaults: defaults)
        check("a prompt survives a relaunch", reloaded.prompts.count == 1)
        check("disabled survives", reloaded.prompts.first?.isEnabled == false)
        check("root-search visibility survives", reloaded.prompts.first?.showsInRootSearch == false)
        if let prompt { reloaded.remove(id: prompt.id) }
        check("a removed prompt stays removed", QuickPromptStore(defaults: defaults).prompts.isEmpty)
    }

    static func replacing() {
        let store = QuickPromptStore(defaults: freshDefaults())
        _ = try? store.add(QuickPrompt(name: "Old", template: "old"))
        let id = UUID()
        let count = store.replace(with: [
            QuickPrompt(id: id, name: "New", template: "new"),
            QuickPrompt(id: id, name: "Again", template: "same id"),
            QuickPrompt(name: "new", template: "same name"),
            QuickPrompt(name: "", template: "nameless")
        ])
        check("a replace drops invalid and duplicate records", count == 1, "got \(count)")
        check("a replace keeps identity", store.prompts.map(\.id) == [id])

        // An old backup decodes with every optional field at its default.
        let json = #"[{"name": "Legacy", "template": "Explain {argument}"}]"#
        let decoded = try? JSONDecoder().decode([QuickPrompt].self, from: Data(json.utf8))
        check("a minimal record decodes", decoded?.first?.isEnabled == true)
        check("and shows in root search", decoded?.first?.showsInRootSearch == true)
    }

    // The words the launcher's strip draws between fields, so it reads as the prompt does.
    static func connectingWords() {
        let translate = SnippetTemplateEngine.connectingWords(
            in: "Translate ~~~{argument name=\"text\"}~~~ to {argument name=\"language\"}")
        check("the word between two fields is kept", translate == ["language": "to"], "got \(translate)")

        let long = SnippetTemplateEngine.connectingWords(
            in: "Rewrite {argument name=\"text\"} so that it sounds formal, then sign it as "
                + "{argument name=\"name\"}.")
        check(
            "a long run keeps the words nearest the field",
            long == ["name": "…sign it as"], "got \(long)")

        let touching = SnippetTemplateEngine.connectingWords(
            in: "{argument name=\"a\"}{argument name=\"b\"}, {argument name=\"c\"}")
        check("punctuation alone draws nothing", touching.isEmpty, "got \(touching)")

        let repeated = SnippetTemplateEngine.connectingWords(
            in: "{argument name=\"a\"} and {argument name=\"a\"} or {argument name=\"b\"}")
        check(
            "a repeated argument keeps its first place", repeated == ["b": "or"], "got \(repeated)")

        let otherToken = SnippetTemplateEngine.connectingWords(
            in: "{argument name=\"a\"} with {selection} for {argument name=\"b\"}")
        check(
            "another token ends the run", otherToken == ["b": "for"], "got \(otherToken)")
    }

    static func identity() {
        let prompt = QuickPrompt(name: "x", template: "y")
        check("an entry id round-trips", QuickPrompt.id(fromEntryID: prompt.entryID) == prompt.id)
        check("another kind's id is not a prompt", QuickPrompt.id(fromEntryID: "quicklink:abc") == nil)
        check("the glyph falls back", prompt.symbol == QuickPrompt.sfSymbol)
    }
}
