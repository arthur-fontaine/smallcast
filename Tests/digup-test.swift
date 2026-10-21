import Foundation
import Observation

/// A stand-in for `digup search-service`: records every request and answers each by its id.
struct StubService {
    let directory: URL
    var executable: URL { directory.appending(path: "digup") }
    var recordedArguments: [String] { lines(of: "args") }
    var recordedModels: String { lines(of: "models").first ?? "" }
    var requests: [String] { lines(of: "requests") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "digup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = directory.path
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(dir)/args'
            printf '%s\\n' "$DIGUP_MODELS" > '\(dir)/models'
            [ -f '\(dir)/refuse' ] && { echo 'error: unknown command search-service' >&2; exit 2; }
            echo '{"event":"ready","index":"/stub"}'
            field() { printf '%s' "$1" | sed -n "s/.*\\"$2\\":\\"*\\([^\\",}]*\\).*/\\1/p"; }
            while IFS= read -r line; do
                printf '%s\\n' "$line" >> '\(dir)/requests'
                id=$(field "$line" id); op=$(field "$line" op); q=$(field "$line" q)
                pass=keyword; [ "$(field "$line" meaning)" = true ] && pass=meaning
                case "$op" in
                prewarm)
                    echo '{"event":"encoder","state":"ready","seconds":0.1}'
                    echo "{\\"id\\":$id,\\"ok\\":true,\\"encoder\\":\\"ready\\"}" ;;
                search)
                    case "$q" in slow) sleep 1 ;; crash) exit 4 ;; esac
                    hits='[]'
                    [ -f "\(dir)/answer-$q" ] && hits=$(cat "\(dir)/answer-$q")
                    [ -f "\(dir)/answer-$q-$pass" ] && hits=$(cat "\(dir)/answer-$q-$pass")
                    echo "{\\"id\\":$id,\\"hits\\":$hits,\\"strong\\":1}" ;;
                *) echo "{\\"id\\":$id,\\"ok\\":true}" ;;
                esac
            done
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func answer(_ query: String, pass: String? = nil, with paths: [String]) throws {
        let hits = paths.map { #"{"path":"\#($0)","kind":"pdf","excerpt":"a «\#(query)» here"}"# }
        let name = "answer-\(query)" + (pass.map { "-\($0)" } ?? "")
        try "[\(hits.joined(separator: ","))]"
            .write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
    }

    func refuse() throws {
        try Data().write(to: directory.appending(path: "refuse"))
    }

    private func lines(of name: String) -> [String] {
        ((try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }
}

/// Counts how often a session's rows change, the way a list redraws.
@MainActor
final class DrawCounter {
    private(set) var count = 0
    private let session: FileSearchSession

    init(_ session: FileSearchSession) {
        self.session = session
        observe()
    }

    private func observe() {
        withObservationTracking { _ = session.results } onChange: { [weak self] in
            Task { @MainActor in
                self?.count += 1
                self?.observe()
            }
        }
    }
}

@main
@MainActor
struct DigUpTests {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() async {
        requests()
        decoding()
        scopes()
        excerpts()
        merging()
        ranking()
        do {
            let stub = try StubService()
            defer { try? FileManager.default.removeItem(at: stub.directory) }
            try await serviceAnswers(stub)
            try await serviceSurvivesCancellationAndCrashes(stub)
            try await sessionPublishesNamesFirst(stub)
            try await sessionCoalescesAWarmAnswer(stub)
            try await sessionWaitsWhenNamesAreUnsure(stub)
            try await sessionHoldsWhatIsDrawn(stub)
            try await coldEncoderAsksKeywordsFirst(stub)
            let old = try StubService()
            defer { try? FileManager.default.removeItem(at: old.directory) }
            try await oldHelperIsUnsupported(old)
        } catch {
            expect(false, "the stub service could be set up: \(error)")
        }
        if failures > 0 { exit(1) }
        print("digup-test passed")
    }

    static func requests() {
        let request = DigUpSearchPolicy.searchRequest(
            id: 7, query: "  lease  ", filter: .all, limit: 6, meaning: true)
        expect(
            request == DigUpServiceRequest(
                id: 7, op: "search", q: "lease", limit: 6, meaning: true, prefixLast: false),
            "a query is trimmed and asked for with its limit")
        expect(
            DigUpSearchPolicy.searchRequest(id: 1, query: "lea", filter: .all, limit: 6, meaning: false)?
                .prefixLast == true,
            "a keyword pass treats the last word as still being typed")
        expect(
            DigUpSearchPolicy.searchRequest(id: 1, query: "   ", filter: .all, limit: 6, meaning: true)
                == nil,
            "a blank query asks nothing")
        expect(
            DigUpSearchPolicy.searchRequest(id: 1, query: "x", filter: .all, limit: 0, meaning: true)
                == nil,
            "a zero limit asks nothing")
        expect(
            DigUpSearchPolicy.searchRequest(id: 1, query: "src", filter: .folders, limit: 6, meaning: true)
                == nil,
            "DigUp indexes no folder, so the Folders filter asks nothing")
        expect(
            DigUpSearchPolicy.searchRequest(id: 1, query: "dog", filter: .images, limit: 6, meaning: true)?
                .kinds == ["screenshot", "image"],
            "a filter becomes kinds")
        let line = DigUpSearchPolicy.searchRequest(
            id: 3, query: "a/b \"c\"", filter: .all, limit: 6, meaning: false)?.line() ?? ""
        let decoded = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        expect(
            decoded?["q"] as? String == "a/b \"c\"" && decoded?["prefix_last"] as? Bool == true
                && decoded?["kinds"] == nil && !line.contains("\n"),
            "a request is one JSON line in the service's own spelling, nil fields left out")
        expect(
            DigUpSearchPolicy.serviceArguments(
                folders: DigUpFolders(
                    roots: ["/Users/t/Documents"], skipped: ["/Users/t/Documents/old"],
                    types: ["heic", "txt"]),
                indexDirectory: "/x")
                == [
                    "search-service", "/Users/t/Documents", "--exclude", "/Users/t/Documents/old",
                    "--exclude-ext", "heic,txt", "--index", "/x"
                ],
            "DigUp's own folder choice and a moved index reach the service")
    }

    static func decoding() {
        let reply = DigUpSearchPolicy.message(
            fromLine: #"{"id":4,"hits":[{"path":"/Users/t/a.pdf","kind":"pdf","excerpt":"«a»","z":3.1}],"strong":1}"#)
        expect(
            reply?.id == 4
                && reply?.hits == [DigUpHit(path: "/Users/t/a.pdf", kind: "pdf", excerpt: "«a»")],
            "a reply decodes its hits, ignoring what File Search doesn't read")
        let event = DigUpSearchPolicy.message(fromLine: #"{"event":"encoder","state":"ready"}"#)
        expect(event?.id == nil && event?.state == "ready", "an event carries no id")
        expect(DigUpSearchPolicy.message(fromLine: "loading model…") == nil, "a stray line is skipped")
    }

    static func scopes() {
        let home = URL(filePath: "/Users/t", directoryHint: .isDirectory)
        let policy = FileSearchPolicy(
            scopes: ["~/Documents", "~/Downloads"],
            ignorePatterns: FileSearchIgnoreList.patterns(
                added: ["~/Documents/private", "*.tmp"], removedDefaults: []),
            homeDirectory: home)
        func admits(_ path: String) -> Bool { DigUpSearchPolicy.admits(path, policy: policy) }
        expect(admits("/Users/t/Documents/lease.pdf"), "a file in a scope is shown")
        expect(!admits("/Users/t/Pictures/dog.heic"), "a file outside every scope is not")
        expect(!admits("/Users/t/DocumentsOld/a.pdf"), "a sibling sharing a scope's prefix is outside it")
        expect(
            !admits("/Users/t/Documents/app/node_modules/x/readme.md"),
            "a shipped ignore rule drops a file below the folder it names")
        expect(!admits("/Users/t/Documents/private/tax.pdf"), "a path rule drops its folder's files")
        expect(!admits("/Users/t/Downloads/part.tmp"), "a name rule drops a file it names")
        let whole = FileSearchPolicy(scopes: ["/"], ignorePatterns: [], homeDirectory: home)
        expect(DigUpSearchPolicy.admits("/Users/t/Pictures/dog.heic", policy: whole), "/ reaches everything")

        let results = DigUpSearchPolicy.results(
            from: [
                DigUpHit(path: "/Users/t/Pictures/b.png", kind: "image"),
                DigUpHit(path: "/Users/t/Documents/a.pdf", kind: "pdf", excerpt: "«a»")
            ],
            policy: policy)
        expect(
            results.map(\.name) == ["a.pdf"] && results.first?.excerpt == "«a»"
                && results.first?.parentPath == "~/Documents",
            "hits outside the scopes drop, and a kept one reads like File Search's own")

        let folders = DigUpFolders(roots: ["/Users/t/Documents/work", "/Users/t/Pictures", "/Users/t"])
        expect(
            DigUpSearchPolicy.reachableRoots(folders, policy: policy)
                == ["/Users/t/Documents/work", "/Users/t"],
            "a DigUp root inside a scope, or around one, is reachable")
    }

    static func excerpts() {
        let runs = DigUpSearchPolicy.excerptRuns("…GET /api/«invoices»/1042 → «facture» de")
        expect(
            runs.map(\.text) == ["…GET /api/", "invoices", "/1042 → ", "facture", " de"]
                && runs.map(\.matched) == [false, true, false, true, false],
            "« » marks become matched runs, without the marks")
        expect(
            DigUpSearchPolicy.excerptRuns("cut «off").map(\.text) == ["cut ", "off"],
            "an unclosed mark keeps the rest as plain text")
    }

    static func merging() {
        let home = URL(fileURLWithPath: "/Users/test")
        func result(_ name: String) -> FileSearchResult {
            FileSearchResult(url: home.appending(path: name), isDirectory: false, homeDirectory: home)
        }
        let policy = FileSearchPolicy(scopes: ["~/Documents"], ignorePatterns: [], homeDirectory: home)
        let split = DigUpSearchPolicy.matches(
            from: ["Documents/a.pdf", "Pictures/b.png", "Documents/c.pdf"].map {
                DigUpHit(path: "/Users/test/" + $0, kind: "pdf")
            },
            strong: 2, policy: policy)
        expect(
            split.strong.map(\.name) == ["a.pdf"] && split.weak.map(\.name) == ["c.pdf"],
            "DigUp's strong count splits its hits before the scopes thin them")
        expect(
            DigUpSearchPolicy.matches(from: [DigUpHit(path: "/Users/test/Documents/a.pdf", kind: "pdf")], strong: 9, policy: policy)
                .strong.count == 1,
            "a strong count past the end keeps every hit strong")
    }

    static func ranking() {
        let home = URL(fileURLWithPath: "/Users/test")
        func result(_ name: String, excerpt: String? = nil) -> FileSearchResult {
            FileSearchResult(url: home.appending(path: name), isDirectory: false, homeDirectory: home, excerpt: excerpt)
        }
        func ranked(_ names: [String], strong: [String] = [], weak: [String] = [], _ query: String)
            -> FileSearchRanking.Ranked
        {
            FileSearchRanking.ranked(
                names: names.map { result($0) },
                content: DigUpMatches(strong: strong.map { result($0) }, weak: weak.map { result($0) }),
                query: query)
        }

        expect(
            ranked(["lease.pdf", "Release notes.md"], strong: ["clause.pdf", "deed.pdf"], weak: ["w.pdf"], "lease")
                .results.map(\.name) == ["lease.pdf", "clause.pdf", "deed.pdf", "Release notes.md", "w.pdf"],
            "a file named what was typed leads, then DigUp's strong matches, then a name matched mid-word")
        expect(
            ranked(["Release notes.md"], strong: ["a.pdf", "b.pdf"], "lease").results.map(\.name)
                == ["a.pdf", "b.pdf", "Release notes.md"],
            "with no name starting a word there, contents lead")
        let both = FileSearchRanking.ranked(
            names: [result("lease agreement.pdf"), result("old lease.pdf")],
            content: DigUpMatches(strong: [result("x.pdf"), result("old lease.pdf", excerpt: "the «lease»")]),
            query: "lease")
        expect(
            both.results.map(\.name) == ["lease agreement.pdf", "old lease.pdf", "x.pdf"],
            "a file found both ways moves up, and shows once")
        expect(both.results[1].excerpt == "the «lease»", "the row found both ways keeps DigUp's passage")
        expect(
            ranked(["notes lease.txt", "lease.pdf"], strong: ["c.pdf"], "lease").results.map(\.name)
                == ["notes lease.txt", "lease.pdf", "c.pdf"],
            "names keep the index's order, which also weighs where they live")
        let crowded = ranked((1...6).map { "lease \($0).pdf" }, strong: ["scan.pdf"], "lease")
        expect(
            crowded.results.count == 7 && crowded.results[4].name == "scan.pdf" && crowded.bestCount == 5,
            "a crowd of names still leaves DigUp's best a place among the best five")
        let alone = ranked(["a.pdf", "b.pdf"], "lease")
        expect(
            alone.results.map(\.name) == ["a.pdf", "b.pdf"] && alone.bestCount == 0,
            "with no content match the index's list is left as it was, with nothing set apart")
        expect(ranked(["lease.pdf"], strong: ["c.pdf"], "lease").bestCount == 0, "a short list sets nothing apart")

        let held = FileSearchRanking.holding(
            [result("a"), result("b"), result("c")],
            against: [result("d"), result("c", excerpt: "x"), result("a")])
        expect(
            held.map(\.name) == ["a", "b", "c", "d"] && held[2].excerpt == "x",
            "held rows keep their places, a dropped one included, and new rows join after them")

        func confident(_ name: String, _ query: String) -> Bool {
            FileSearchRanking.isConfident([result(name)], query: query)
        }
        expect(confident("lease.pdf", "lease") && confident("myLease.pdf", "lease"), "a word-start name is sure")
        expect(confident("Résumé 2024.pdf", "resume"), "a name is compared folded, as the index folds it")
        expect(!confident("mylease.pdf", "lease") && !confident("Untitled.txt", "lease"), "a mid-word name is not")
        expect(!FileSearchRanking.isConfident([], query: "lease"), "no name is not sure of anything")
    }

    static func service(_ stub: StubService, roots: [String] = []) -> DigUpSearchService {
        DigUpSearchService(
            launch: .init(helper: stub.executable, indexDirectory: "/tmp/index", modelsDirectory: "/tmp/models"),
            folders: DigUpFolders(roots: roots))
    }

    static func serviceAnswers(_ stub: StubService) async throws {
        try stub.answer("lease", with: ["/Users/t/lease.pdf", "/Users/t/dog.heic"])
        let service = service(stub, roots: ["/Users/t"])
        defer { service.stop() }
        let hits = try await service.search("lease", filter: .all, limit: 6, meaning: true).hits ?? []
        expect(hits.map(\.path) == ["/Users/t/lease.pdf", "/Users/t/dog.heic"], "the service's hits come back")
        expect(
            stub.recordedArguments == ["search-service", "/Users/t", "--index", "/tmp/index"],
            "the service starts on DigUp's folders and index")
        expect(stub.recordedModels == "/tmp/models", "a moved model folder reaches the service")
        let again = try await service.search("lease", filter: .all, limit: 6, meaning: true).hits ?? []
        expect(again.count == 2 && stub.recordedArguments.count == 4, "a second search reuses the process")

        expect(!service.isEncoderReady, "the encoder is cold until DigUp says otherwise")
        service.prewarm()
        await waitUntil(seconds: 2) { service.isEncoderReady }
        service.folders = DigUpFolders(roots: ["/Users/t/Documents"])
        await waitUntil(seconds: 2) { stub.requests.last?.contains(#""op":"folders""#) == true }
        expect(
            stub.requests.last?.contains(#""roots":["/Users/t/Documents"]"#) == true,
            "a changed folder choice reaches the running service")
    }

    static func serviceSurvivesCancellationAndCrashes(_ stub: StubService) async throws {
        try stub.answer("fresh", with: ["/Users/t/fresh.pdf"])
        let service = service(stub)
        defer { service.stop() }
        let started = ContinuousClock.now
        let slow = Task { try await service.search("slow", filter: .all, limit: 6, meaning: true) }
        try? await Task.sleep(for: .milliseconds(100))
        slow.cancel()
        let outcome = await slow.result
        expect(ContinuousClock.now - started < .milliseconds(800), "a cancelled search returns at once")
        if case .success = outcome { expect(false, "a cancelled search publishes nothing") }
        let fresh = try await service.search("fresh", filter: .all, limit: 6, meaning: true).hits ?? []
        expect(
            fresh.map(\.path) == ["/Users/t/fresh.pdf"],
            "the stale reply that arrives later is not mistaken for the next query's")

        do {
            _ = try await service.search("crash", filter: .all, limit: 6, meaning: true)
            expect(false, "a service that dies fails the search it was answering")
        } catch {
            expect(error as? DigUpSearchService.Failure == .ended, "a crash ends the pending search")
        }
        let after = try await service.search("fresh", filter: .all, limit: 6, meaning: true).hits ?? []
        expect(after.count == 1 && !service.isUnsupported, "the next search starts the service again")
    }

    static func oldHelperIsUnsupported(_ stub: StubService) async throws {
        try stub.refuse()
        let service = service(stub)
        do {
            _ = try await service.search("lease", filter: .all, limit: 6, meaning: true)
            expect(false, "a helper without the service fails the search")
        } catch {}
        expect(service.isUnsupported, "a helper that exits before it is ready is unsupported")
        do {
            _ = try await service.search("lease", filter: .all, limit: 6, meaning: true)
            expect(false, "an unsupported helper is not launched again")
        } catch {
            expect(error as? DigUpSearchService.Failure == .notRunning, "it says it is not running")
        }
    }

    static func names(_ found: [String], delay: Duration = .zero) -> FileSearchSession.SearchOperation {
        { _, _ in
            if delay > .zero { try? await Task.sleep(for: delay) }
            let home = URL(fileURLWithPath: "/Users/t")
            return found.map { FileSearchResult(url: home.appending(path: $0), isDirectory: false, homeDirectory: home) }
        }
    }

    static func digUp(_ service: DigUpSearchService) -> DigUpSearch {
        DigUpSearch(
            service: service, limit: 50,
            policy: FileSearchPolicy(
                scopes: ["/"], ignorePatterns: [], homeDirectory: URL(fileURLWithPath: "/Users/t")))
    }

    static func sessionPublishesNamesFirst(_ stub: StubService) async throws {
        try stub.answer("slow", with: ["/Users/t/clause.pdf"])
        let service = service(stub)
        defer { service.stop() }
        service.prewarm()
        await waitUntil(seconds: 2) { service.isEncoderReady }
        let session = FileSearchSession(searchOperation: names(["slow notes.txt", "clause.pdf"]))
        session.digUp = digUp(service)

        session.search("slow")
        await waitUntil(seconds: 1) { session.state == .ready }
        expect(
            session.results.map(\.name) == ["slow notes.txt", "clause.pdf"] && session.isSearchingContent,
            "names show while DigUp is still reading, past the grace")
        await waitUntil(seconds: 3) { !session.isSearchingContent }
        expect(
            session.results.map(\.name) == ["slow notes.txt", "clause.pdf"],
            "the typed name keeps the top row, and a file found both ways shows once")
        expect(session.results.last?.excerpt == "a «slow» here", "the content row carries its excerpt")

        session.digUp = nil
        expect(session.results.isEmpty && session.state == .idle, "switching engine drops the rows")
        session.search("slow")
        await waitUntil(seconds: 1) { session.state == .ready }
        expect(
            !session.isSearchingContent && session.results.count == 2,
            "with the Name engine the same session searches the index alone")
    }

    static func sessionCoalescesAWarmAnswer(_ stub: StubService) async throws {
        try stub.answer("deed", with: ["/Users/t/deed.pdf"])
        let service = service(stub)
        defer { service.stop() }
        service.prewarm()
        await waitUntil(seconds: 2) { service.isEncoderReady }
        let session = FileSearchSession(searchOperation: names(["deed notes.txt"]))
        session.digUp = digUp(service)
        let drawn = DrawCounter(session)
        session.search("deed")
        await waitUntil(seconds: 2) { session.state == .ready && !session.isSearchingContent }
        expect(
            session.results.map(\.name) == ["deed.pdf", "deed notes.txt"] && drawn.count == 1,
            "a warm DigUp answers within the grace, so the list is drawn once, its exact name first")

        session.search("crash")
        await waitUntil(seconds: 2) { session.state == .ready && !session.isSearchingContent }
        expect(
            session.results.map(\.name) == ["deed notes.txt"],
            "a failing DigUp still leaves the name search")
    }

    static func sessionWaitsWhenNamesAreUnsure(_ stub: StubService) async throws {
        try stub.answer("slow", with: ["/Users/t/clause.pdf"])
        let service = service(stub)
        defer { service.stop() }
        service.prewarm()
        await waitUntil(seconds: 2) { service.isEncoderReady }
        let session = FileSearchSession(searchOperation: names(["Untitled.txt"]))
        session.digUp = digUp(service)
        session.search("slow")
        try? await Task.sleep(for: .milliseconds(200))
        expect(session.state == .searching, "a name that only contains the query waits past the grace")
        await waitUntil(seconds: 1) { session.state == .ready }
        expect(
            session.results.map(\.name) == ["Untitled.txt"] && session.isSearchingContent,
            "past the patience the names show anyway")
        await waitUntil(seconds: 3) { !session.isSearchingContent }
        expect(session.results.map(\.name) == ["clause.pdf", "Untitled.txt"], "and DigUp's answer then leads")
    }

    static func sessionHoldsWhatIsDrawn(_ stub: StubService) async throws {
        try stub.answer("slow", with: ["/Users/t/clause.pdf"])
        let service = service(stub)
        defer { service.stop() }
        service.prewarm()
        await waitUntil(seconds: 2) { service.isEncoderReady }
        let session = FileSearchSession(searchOperation: names(["Untitled.txt", "zeta.txt"]))
        var moved = false
        session.holdsOrder = { moved }
        session.digUp = digUp(service)
        session.search("slow")
        await waitUntil(seconds: 1) { session.state == .ready }
        moved = true
        await waitUntil(seconds: 3) { !session.isSearchingContent }
        expect(
            session.results.map(\.name) == ["Untitled.txt", "zeta.txt", "clause.pdf"] && session.heldCount == 2,
            "off the first row the drawn rows keep their places, and DigUp's file joins below them")
        moved = false
        session.search("slower")
        await waitUntil(seconds: 1) { session.state == .ready }
        expect(session.heldCount == nil, "a new query holds nothing")
    }

    static func coldEncoderAsksKeywordsFirst(_ stub: StubService) async throws {
        try stub.answer("cold", pass: "keyword", with: ["/Users/t/cold-k.pdf"])
        try stub.answer("cold", pass: "meaning", with: ["/Users/t/cold-m.pdf"])
        let service = service(stub)
        defer { service.stop() }
        let session = FileSearchSession(searchOperation: names([]))
        session.digUp = digUp(service)
        let before = stub.requests.count
        session.search("cold")
        await waitUntil(seconds: 2) { !session.isSearchingContent && session.state == .ready }
        let asked = stub.requests.dropFirst(before).filter { $0.contains(#""q":"cold""#) }
        expect(
            asked.count == 2 && asked.first?.contains(#""meaning":false"#) == true
                && asked.last?.contains(#""meaning":true"#) == true,
            "a cold encoder is asked for keywords first, then for meaning")
        expect(session.results.map(\.name) == ["cold-m.pdf"], "the meaning answer replaces the keyword one")
    }

    static func waitUntil(seconds: Int, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(condition(), "the async operation completed before the timeout")
    }
}
