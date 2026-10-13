import Foundation

/// A stand-in for DigUp's helper: it records its arguments, then answers by query.
struct StubHelper {
    let directory: URL
    var executable: URL { directory.appending(path: "digup") }
    var answer: URL { directory.appending(path: "answer.json") }
    var recordedArguments: [String] {
        (try? String(contentsOf: directory.appending(path: "args"), encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) ?? []
    }
    var recordedModels: String {
        ((try? String(contentsOf: directory.appending(path: "models"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .newlines)
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "digup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(directory.path)/args'
            printf '%s\\n' "$DIGUP_MODELS" > '\(directory.path)/models'
            case "$2" in
                slow) sleep 20 ;;
                boom) exit 3 ;;
            esac
            cat '\(answer.path)'
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func makeFile(_ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data().write(to: url)
        return url
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
        arguments()
        decoding()
        merging()
        do {
            let stub = try StubHelper()
            defer { try? FileManager.default.removeItem(at: stub.directory) }
            try await runnerAnswers(stub)
            await runnerFailure(stub)
            await cancellationEndsTheHelper(stub)
            try await sessionAddsDigUpToNames(stub)
        } catch {
            expect(false, "the stub helper could be set up: \(error)")
        }
        if failures > 0 { exit(1) }
        print("digup-test passed")
    }

    static func arguments() {
        expect(
            DigUpSearchPolicy.arguments(query: "  lease  ", limit: 6, filter: .all, indexDirectory: nil)
                == ["search", "lease", "-n", "6", "--json"],
            "a query is trimmed and asked for as JSON with its limit")
        expect(
            DigUpSearchPolicy.arguments(query: "   ", limit: 6, filter: .all, indexDirectory: nil) == nil,
            "a blank query asks nothing")
        expect(
            DigUpSearchPolicy.arguments(query: "x", limit: 0, filter: .all, indexDirectory: nil) == nil,
            "a zero limit asks nothing")
        expect(
            DigUpSearchPolicy.arguments(query: "src", limit: 6, filter: .folders, indexDirectory: nil)
                == nil,
            "DigUp indexes no folder, so the Folders filter asks nothing")
        expect(
            DigUpSearchPolicy.arguments(query: "dog", limit: 6, filter: .images, indexDirectory: "/x")
                == ["search", "dog", "-n", "6", "--json", "--kind", "screenshot,image", "--index", "/x"],
            "a filter becomes --kind, and a moved index becomes --index")
        expect(
            DigUpSearchPolicy.arguments(query: "-n 3", limit: 6, filter: .all, indexDirectory: nil)?[1]
                == " -n 3",
            "a leading dash is kept a word, not read as an option")
        expect(DigUpSearchPolicy.kinds(for: .documents) == ["pdf", "doc"], "documents are PDFs and docs")
    }

    static func decoding() {
        let json = """
            [
              {
                "excerpt" : "the «pet» clause",
                "kind" : "pdf",
                "loc" : 3,
                "path" : "/Users/test/lease.pdf",
                "score" : 4.2,
                "segment" : "page",
                "z" : 3.1
              },
              { "kind" : "video", "loc" : 6.5, "path" : "/Users/test/zebra.mov", "segment" : "frame" }
            ]
            """
        let hits = try? DigUpSearchPolicy.hits(fromJSON: Data(json.utf8))
        expect(
            hits == [
                DigUpHit(path: "/Users/test/lease.pdf", kind: "pdf"),
                DigUpHit(path: "/Users/test/zebra.mov", kind: "video")
            ],
            "the helper's rows decode in order, ignoring what File Search doesn't read")
        expect(
            (try? DigUpSearchPolicy.hits(fromJSON: Data("[]".utf8))) == [],
            "no good matches is an empty list")

        let home = URL(fileURLWithPath: "/Users/test")
        let results = DigUpSearchPolicy.results(
            from: [
                DigUpHit(path: "/Users/test/gone.pdf", kind: "pdf"),
                DigUpHit(path: "/Users/test/b.png", kind: "image"),
                DigUpHit(path: "/Users/test/a.pdf", kind: "pdf")
            ],
            homeDirectory: home
        ) { $0.hasSuffix("gone.pdf") ? nil : false }
        expect(
            results.map(\.name) == ["b.png", "a.pdf"],
            "a file deleted since DigUp indexed it is dropped, and DigUp's order kept")
        expect(results.first?.parentPath == "~", "a result reads like File Search's own")
    }

    static func runnerAnswers(_ stub: StubHelper) async throws {
        let first = try stub.makeFile("lease.pdf")
        let second = try stub.makeFile("dog.heic")
        let json = """
            [{"path": "\(first.path)", "kind": "pdf"},
             {"path": "\(stub.directory.path)/missing.pdf", "kind": "pdf"},
             {"path": "\(second.path)", "kind": "image"}]
            """
        try json.write(to: stub.answer, atomically: true, encoding: .utf8)
        let runner = DigUpSearchRunner(
            helper: stub.executable, indexDirectory: "/tmp/index", modelsDirectory: "/tmp/models",
            limit: 6)
        let results = try await runner.results(
            for: "lease", filter: .all, homeDirectory: stub.directory)
        expect(results.map(\.name) == ["lease.pdf", "dog.heic"], "the helper's files come back")
        expect(
            stub.recordedArguments
                == ["search", "lease", "-n", "6", "--json", "--index", "/tmp/index"],
            "the helper is asked with the policy's arguments")
        expect(stub.recordedModels == "/tmp/models", "a moved model folder reaches the helper")
    }

    static func runnerFailure(_ stub: StubHelper) async {
        let runner = DigUpSearchRunner(
            helper: stub.executable, indexDirectory: nil, modelsDirectory: nil, limit: 6)
        do {
            _ = try await runner.results(for: "boom", filter: .all, homeDirectory: stub.directory)
            expect(false, "a failing helper throws")
        } catch let failure as DigUpSearchRunner.Failure {
            expect(failure.status == 3, "the helper's exit status is reported")
        } catch {
            expect(false, "a failing helper throws its status, not \(error)")
        }
    }

    static func cancellationEndsTheHelper(_ stub: StubHelper) async {
        let runner = DigUpSearchRunner(
            helper: stub.executable, indexDirectory: nil, modelsDirectory: nil, limit: 6)
        let started = ContinuousClock.now
        let task = Task {
            try await runner.results(for: "slow", filter: .all, homeDirectory: stub.directory)
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let outcome = await task.result
        expect(ContinuousClock.now - started < .seconds(5), "cancelling ends a running helper")
        if case .success = outcome { expect(false, "a cancelled search publishes nothing") }
    }

    static func sessionAddsDigUpToNames(_ stub: StubHelper) async throws {
        let clause = try stub.makeFile("clause.pdf")
        let notes = try stub.makeFile("lease notes.txt")
        try #"[{"path": "\#(clause.path)", "kind": "pdf"}]"#
            .write(to: stub.answer, atomically: true, encoding: .utf8)
        let home = FileManager.default.homeDirectoryForCurrentUser
        nonisolated(unsafe) var nameCalls = 0
        let session = FileSearchSession { _, _ in
            nameCalls += 1
            return [notes, clause].map {
                FileSearchResult(url: $0, isDirectory: false, homeDirectory: home)
            }
        }
        session.digUp = DigUpSearchRunner(
            helper: stub.executable, indexDirectory: nil, modelsDirectory: nil, limit: 6)

        let started = ContinuousClock.now
        session.search("slow")
        try? await Task.sleep(for: .milliseconds(150))
        session.search("pet clause")
        await waitUntil(seconds: 5) { session.state == .ready }
        expect(
            session.results.map(\.name) == ["clause.pdf", "lease notes.txt"],
            "DigUp's files lead, then the name matches it did not return")
        expect(
            ContinuousClock.now - started < .seconds(5),
            "a newer query cancels the slow one instead of waiting it out")

        session.search("boom")
        await waitUntil(seconds: 5) { session.state == .ready }
        expect(
            session.results.map(\.name) == ["lease notes.txt", "clause.pdf"],
            "a failing DigUp still leaves the name search")

        session.digUp = nil
        expect(session.results.isEmpty && session.state == .idle, "switching engine drops the rows")
        let callsBefore = nameCalls
        session.search("pet clause")
        await waitUntil(seconds: 1) { session.state == .ready }
        expect(
            nameCalls == callsBefore + 1 && session.results.count == 2,
            "with the Name engine the same session searches the index alone")
    }

    static func merging() {
        let home = URL(fileURLWithPath: "/Users/test")
        func result(_ name: String) -> FileSearchResult {
            FileSearchResult(url: home.appending(path: name), isDirectory: false, homeDirectory: home)
        }
        let merged = DigUpSearchPolicy.merged(
            content: [result("b.pdf"), result("a.png")], names: [result("a.png"), result("c.txt")])
        expect(merged.map(\.name) == ["b.pdf", "a.png", "c.txt"], "a file found both ways shows once")
        expect(
            DigUpSearchPolicy.merged(content: [], names: [result("c.txt")]).map(\.name) == ["c.txt"],
            "no content match leaves the name search as it was")
    }

    static func waitUntil(seconds: Int, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(condition(), "the async operation completed before the timeout")
    }
}
