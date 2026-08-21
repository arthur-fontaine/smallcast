import Foundation

@main
@MainActor
struct AITests {
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
        describesProviders()
        buildsEndpoints()
        buildsRequests()
        decodesServerSentEvents()
        decodesSplitChunks()
        decodesOllama()
        reportsThinking()
        listsModels()
        reportsErrors()
        readsErrorBodies()
        namesConversations()
        prunesArchive()
        roundTripsArchive()
        splitsMarkdown()
        mapsChords()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Provider table

    static func describesProviders() {
        expect(AIProvider.openAICompatible.needsAPIKey, "a hosted endpoint needs a credential")
        expect(!AIProvider.ollama.needsAPIKey, "a local daemon does not")
        expect(!AIProvider.lmStudio.needsAPIKey, "and neither does LM Studio")
        expect(AIProvider.openAICompatible.chatPath == "chat/completions", "OpenAI's chat path")
        expect(AIProvider.ollama.chatPath == "api/chat", "Ollama's chat path")
        expect(
            AIProvider.lmStudio.chatPath == AIProvider.openAICompatible.chatPath
                && AIProvider.lmStudio.modelsPath == AIProvider.openAICompatible.modelsPath,
            "LM Studio speaks the OpenAI API, so it shares both paths")
        expect(
            AIProvider.allCases.allSatisfy { !$0.defaultBaseURL.isEmpty },
            "every provider ships an address to start from")
        expect(
            AIProvider.lmStudio.defaultModel.isEmpty,
            "LM Studio names a model by what was downloaded, so there is nothing to guess")
        expect(
            Set(AIProvider.allCases.map(\.rawValue)).count == AIProvider.allCases.count,
            "raw values are the persisted spelling and stay distinct")
    }

    static func buildsEndpoints() {
        expect(
            AIProviderConfig.endpoint(baseURL: "https://x.dev/v1", path: "chat/completions")?
                .absoluteString == "https://x.dev/v1/chat/completions",
            "the path is appended to the base")
        expect(
            AIProviderConfig.endpoint(baseURL: "https://x.dev/v1///", path: "api/chat")?
                .absoluteString == "https://x.dev/v1/api/chat",
            "trailing slashes never double the separator")
        expect(
            AIProviderConfig.endpoint(baseURL: "  ", path: "api/chat") == nil,
            "a blank address is no address")
        expect(
            AIProviderConfig.endpoint(baseURL: "localhost:11434", path: "api/chat") == nil,
            "an address without a scheme is rejected rather than guessed at")

        let ollama = AIProviderConfig(
            provider: .ollama, baseURL: "http://localhost:11434", model: "llama3.2")
        expect(ollama.isUsable, "Ollama is usable with no key")
        let hosted = AIProviderConfig(
            provider: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini")
        expect(!hosted.isUsable, "a hosted provider without a key is not usable")
        let keyed = AIProviderConfig(
            provider: .openAICompatible, baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini", apiKey: "sk-test")
        expect(keyed.isUsable, "…and is once a key is stored")
        let modelless = AIProviderConfig(
            provider: .ollama, baseURL: "http://localhost:11434", model: "  ")
        expect(!modelless.isUsable, "a blank model is not usable")
    }

    // MARK: - Requests

    static func buildsRequests() {
        let config = AIProviderConfig(
            provider: .openAICompatible, baseURL: "https://x.dev/v1", model: "m",
            apiKey: " sk-test ", systemPrompt: "  Be brief.  ")
        let messages = [
            AIMessage(role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 0)),
            AIMessage(role: .assistant, text: "hello", createdAt: Date(timeIntervalSince1970: 1))
        ]
        guard let request = try? AIRequestBuilder.chat(config: config, messages: messages) else {
            expect(false, "builds a request for a usable config")
            return
        }
        expect(
            request.url.absoluteString == "https://x.dev/v1/chat/completions",
            "posts to the provider's chat path")
        expect(
            request.headers["Authorization"] == "Bearer sk-test",
            "the key is trimmed into a bearer header")
        expect(
            request.headers["Content-Type"] == "application/json", "the body is declared as JSON")

        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        expect(body?["model"] as? String == "m", "the model rides the body")
        expect(body?["stream"] as? Bool == true, "streaming is always asked for")
        let turns = body?["messages"] as? [[String: String]] ?? []
        expect(turns.count == 3, "the system prompt is prepended as its own turn")
        expect(turns.first?["role"] == "system", "…in first position")
        expect(turns.first?["content"] == "Be brief.", "…trimmed")
        expect(turns.last?["role"] == "assistant", "the transcript keeps its own order")

        let bare = AIProviderConfig(provider: .ollama, baseURL: "http://h:1", model: "m")
        guard let plain = try? AIRequestBuilder.chat(config: bare, messages: messages) else {
            expect(false, "builds a request with no key and no system prompt")
            return
        }
        expect(plain.headers["Authorization"] == nil, "no key means no blank auth header")
        let plainBody = (try? JSONSerialization.jsonObject(with: plain.body)) as? [String: Any]
        expect(
            (plainBody?["messages"] as? [[String: String]])?.count == 2,
            "an empty system prompt adds no turn")

        let broken = AIProviderConfig(provider: .ollama, baseURL: "", model: "m")
        var threw = false
        do {
            _ = try AIRequestBuilder.chat(config: broken, messages: messages)
        } catch {
            threw = true
        }
        expect(threw, "an unusable address throws rather than building half a request")
    }

    // MARK: - Stream decoding

    private static func chunk(_ text: String) -> Data { Data(text.utf8) }

    private static func delta(_ content: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(content)\"}}]}\n"
    }

    static func decodesServerSentEvents() {
        var decoder = AIStreamDecoder(provider: .openAICompatible)
        var events = decoder.consume(chunk(delta("Hel") + delta("lo")))
        expect(events == [.delta("Hel"), .delta("lo")], "two framed deltas in one chunk")
        events = decoder.consume(chunk(": keep-alive\n\ndata: [DONE]\n"))
        expect(events == [.done], "a comment is skipped and the sentinel ends the stream")
        expect(decoder.finish().isEmpty, "nothing is left buffered")

        var whole = AIStreamDecoder(provider: .openAICompatible)
        let full = "data: {\"choices\":[{\"message\":{\"content\":\"whole\"}}]}\n"
        expect(
            whole.consume(chunk(full)) == [.delta("whole")],
            "a server that streams whole messages still decodes")
    }

    static func decodesSplitChunks() {
        var decoder = AIStreamDecoder(provider: .openAICompatible)
        let line = delta("é")
        let bytes = Array(line.utf8)
        // Split inside the two-byte scalar: decoding each half alone would lose the character.
        let cut = bytes.firstIndex(of: 0xC3) ?? 1
        expect(
            decoder.consume(Data(bytes[..<(cut + 1)])).isEmpty,
            "a line without its newline is held back")
        expect(
            decoder.consume(Data(bytes[(cut + 1)...])) == [.delta("é")],
            "the held bytes join the next chunk, scalar intact")

        var trailing = AIStreamDecoder(provider: .openAICompatible)
        let unterminated = String(delta("tail").dropLast())
        expect(trailing.consume(chunk(unterminated)).isEmpty, "…still held with no newline")
        expect(trailing.finish() == [.delta("tail")], "and flushed when the body ends")
    }

    static func decodesOllama() {
        var decoder = AIStreamDecoder(provider: .ollama)
        let events = decoder.consume(
            chunk(
                "{\"message\":{\"content\":\"Hi\"},\"done\":false}\n"
                    + "{\"message\":{\"content\":\"\"},\"done\":true}\n"))
        expect(events == [.delta("Hi"), .done], "NDJSON deltas, then its own done marker")

        var unframed = AIStreamDecoder(provider: .ollama)
        expect(
            unframed.consume(chunk("data: {\"message\":{\"content\":\"x\"}}\n")).isEmpty,
            "NDJSON does not read SSE framing")
    }

    static func reportsThinking() {
        var decoder = AIStreamDecoder(provider: .lmStudio)
        let thinking = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Okay\"}}]}\n"
        expect(
            decoder.consume(chunk(thinking)) == [.reasoning],
            "a reasoning-only chunk says the model is working")
        expect(
            decoder.consume(chunk(delta("Answer"))) == [.delta("Answer")],
            "the answer itself is still a delta")
        var both = AIStreamDecoder(provider: .lmStudio)
        let mixed =
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"x\",\"content\":\"y\"}}]}\n"
        expect(
            both.consume(chunk(mixed)) == [.delta("y")],
            "a chunk carrying both is the answer — reasoning never joins the transcript")
    }

    static func listsModels() {
        let openAI = Data(
            """
            {"data":[{"id":"qwen3.5-0.8b"},{"id":"google/gemma-4-e2b"},
            {"id":"text-embedding-nomic-embed-text-v1.5"},{"id":""}]}
            """.utf8)
        expect(
            AIModelList.decode(openAI, provider: .lmStudio)
                == ["google/gemma-4-e2b", "qwen3.5-0.8b"],
            "LM Studio's listing is sorted, blanks and embedding models dropped")
        expect(
            AIModelList.decode(openAI, provider: .openAICompatible).count == 2,
            "the same shape serves every OpenAI-compatible server")
        let ollama = Data("{\"models\":[{\"name\":\"llama3.2\"},{\"name\":\"llama3.2\"}]}".utf8)
        expect(
            AIModelList.decode(ollama, provider: .ollama) == ["llama3.2"],
            "Ollama's own shape, deduplicated")
        expect(
            AIModelList.decode(ollama, provider: .lmStudio).isEmpty,
            "the wrong shape lists nothing rather than guessing")
        expect(
            AIModelList.decode(Data("not json".utf8), provider: .lmStudio).isEmpty,
            "an unreadable listing lists nothing")
    }

    static func reportsErrors() {
        var sse = AIStreamDecoder(provider: .openAICompatible)
        expect(
            sse.consume(chunk("data: {\"error\":{\"message\":\"nope\"}}\n")) == [.failed("nope")],
            "an object error carries its message")
        var ndjson = AIStreamDecoder(provider: .ollama)
        expect(
            ndjson.consume(chunk("{\"error\":\"model not found\"}\n"))
                == [.failed("model not found")],
            "a bare string error is a message too")
        var unframed = AIStreamDecoder(provider: .openAICompatible)
        expect(
            unframed.consume(chunk("{\"error\":{\"message\":\"bad key\"}}\n"))
                == [.failed("bad key")],
            "an unframed error body is reported rather than dropped")
    }

    static func readsErrorBodies() {
        expect(
            AIStreamDecoder.message(in: "{\"error\":{\"message\":\"no credit\"}}") == "no credit",
            "a rejected request's body is read for its reason")
        expect(AIStreamDecoder.message(in: "not json") == nil, "a body with no reason says nothing")
    }

    // MARK: - Conversations

    static func namesConversations() {
        expect(AIConversation.title(from: "") == "New Chat", "an unasked chat has a placeholder")
        expect(
            AIConversation.title(from: "  How do I ship?\nmore") == "How do I ship?",
            "the first line, trimmed, is the title")
        let long = String(repeating: "a", count: AIConversation.titleLimit + 20)
        expect(
            AIConversation.title(from: long).count == AIConversation.titleLimit + 1,
            "a long question is cut to the limit plus its ellipsis")

        let chat = AIConversation(
            messages: [
                AIMessage(role: .user, text: "q", createdAt: Date(timeIntervalSince1970: 0)),
                AIMessage(
                    role: .assistant, text: "", createdAt: Date(timeIntervalSince1970: 1),
                    failure: "boom")
            ],
            updatedAt: Date(timeIntervalSince1970: 1))
        expect(chat.title == "q", "the title comes from the question, not the answer")
        expect(
            chat.contextMessages.count == 1,
            "a failed turn is not sent back as context — it asked and answered nothing")
    }

    static func prunesArchive() {
        let old = AIConversation(
            messages: [AIMessage(role: .user, text: "old", createdAt: Date(timeIntervalSince1970: 0))],
            updatedAt: Date(timeIntervalSince1970: 10))
        let new = AIConversation(
            messages: [AIMessage(role: .user, text: "new", createdAt: Date(timeIntervalSince1970: 0))],
            updatedAt: Date(timeIntervalSince1970: 20))
        let empty = AIConversation(updatedAt: Date(timeIntervalSince1970: 30))
        let pruned = AIConversationArchive.pruned([old, empty, new])
        expect(pruned.map(\.id) == [new.id, old.id], "newest first")
        expect(pruned.count == 2, "a chat with nothing in it is not history")
        expect(
            AIConversationArchive.pruned([old, new], limit: 1).map(\.id) == [new.id],
            "the cap keeps the newest")
    }

    static func roundTripsArchive() {
        let chat = AIConversation(
            messages: [
                AIMessage(role: .user, text: "q", createdAt: Date(timeIntervalSince1970: 100)),
                AIMessage(role: .assistant, text: "a", createdAt: Date(timeIntervalSince1970: 101))
            ],
            updatedAt: Date(timeIntervalSince1970: 101))
        guard let data = try? AIConversationArchive.encode([chat]),
            let back = try? AIConversationArchive.decode(data)
        else {
            expect(false, "a transcript survives the file")
            return
        }
        expect(back == [chat], "…unchanged, ids and dates included")
    }

    // MARK: - Markdown blocks

    static func splitsMarkdown() {
        let blocks = AIMarkdownBlock.parse(
            """
            # Title
            One line
            and its continuation.

            - first
            - second
            1. one
            2. two
            > quoted
            ---
            ```swift
            let x = 1
            ```
            """)
        expect(blocks.contains(.heading(level: 1, text: "Title")), "a heading is its own block")
        expect(
            blocks.contains(.paragraph("One line and its continuation.")),
            "wrapped lines join one paragraph")
        expect(blocks.contains(.bullet("second")), "bullets split")
        expect(
            blocks.contains(.numbered(index: 2, text: "two")),
            "an ordered list is renumbered from what it actually shows")
        expect(blocks.contains(.quote("quoted")), "a quote splits")
        expect(blocks.contains(.rule), "a rule splits")
        expect(
            blocks.contains(.code(language: "swift", text: "let x = 1")),
            "a fence keeps its language and its lines verbatim")

        let mid = AIMarkdownBlock.parse("```python\nprint(1)")
        expect(
            mid == [.code(language: "python", text: "print(1)")],
            "an unterminated fence mid-stream still renders as code")
        expect(
            AIMarkdownBlock.parse("```\ntext\n```\nafter").count == 2,
            "a fence with no language closes and the text after it is its own block")
    }

    // MARK: - The chord

    static func mapsChords() {
        expect(PaletteAIChord.optionReturn.key == .returnKey, "⌥↵ ends on Return")
        expect(PaletteAIChord.tab.key == .tab, "Tab ends on Tab")
        expect(PaletteAIChord.tab.modifier == nil, "Tab holds nothing")
        expect(
            PaletteAIChord.allCases.allSatisfy { !$0.keycaps.isEmpty },
            "every chord has keycaps to draw")
        expect(
            Set(PaletteAIChord.allCases.map(\.rawValue)).count == PaletteAIChord.allCases.count,
            "raw values are the persisted spelling and stay distinct")
    }
}
