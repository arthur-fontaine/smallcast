import Foundation

@main
@MainActor
struct AIProviderTests {
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
        providerPresetsResolveEndpoints()
        modelCatalogBuildsProviderRequests()
        modelCatalogDecodesProviderResponses()
        modelCatalogSearchesWithoutRenderingEverything()
        endpointPolicyRejectsUnsafeRemoteURLs()
        storedKeysDoNotFollowARetargetedConnection()
        sseFramesSurviveSplits()
        openAIAndAnthropicStreamsDecode()
        capturedStreamsDecodeHoweverTheyArrive()
        brokenStreamsFailLoudly()
        brandsResolveFromModelIDs()
        codexProtocolFramesRoundTrip()
        settingsPersistAndRepairSelections()
        subscriptionSelectionsReconcile()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func providerPresetsResolveEndpoints() {
        let expected: [(AIProviderKind, String)] = [
            (.openAI, "https://api.openai.com/v1/chat/completions"),
            (.anthropic, "https://api.anthropic.com/v1/messages"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"),
            (.openRouter, "https://openrouter.ai/api/v1/chat/completions"),
            (.openAICompatible, "https://api.openai.com/v1/chat/completions")
        ]
        for (provider, endpoint) in expected {
            let configuration = AIHTTPConfiguration(
                provider: provider,
                baseURL: URL(string: provider.defaultBaseURL)!,
                model: "model")
            expect(
                configuration.endpointURL.absoluteString == endpoint,
                "\(provider.title) resolves its documented streaming endpoint")
        }
        let explicit = AIHTTPConfiguration(
            provider: .openAICompatible,
            baseURL: URL(string: "https://example.com/chat/completions")!,
            model: "model")
        expect(
            explicit.endpointURL.absoluteString == "https://example.com/chat/completions",
            "an explicit completion endpoint is not appended twice")
    }

    static func modelCatalogBuildsProviderRequests() {
        let expected: [(AIProviderKind, String)] = [
            (.openAI, "https://api.openai.com/v1/models"),
            (.anthropic, "https://api.anthropic.com/v1/models?limit=1000"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000"),
            (.openRouter, "https://openrouter.ai/api/v1/models/user"),
            (.openAICompatible, "https://api.openai.com/v1/models")
        ]
        for (provider, endpoint) in expected {
            let query = try? AIModelDiscovery.query(
                provider: provider, baseURL: URL(string: provider.defaultBaseURL)!,
                apiKey: "secret", appTitle: "Smallcast")
            expect(
                query?.request.url?.absoluteString == endpoint,
                "\(provider.title) resolves its model catalog endpoint")
        }

        let anthropic = try? AIModelDiscovery.query(
            provider: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "secret", appTitle: "Smallcast"
        ).request
        expect(
            anthropic?.value(forHTTPHeaderField: "x-api-key") == "secret",
            "Anthropic model discovery uses x-api-key authentication")
        let gemini = try? AIModelDiscovery.query(
            provider: .gemini, baseURL: URL(string: AIProviderKind.gemini.defaultBaseURL)!,
            apiKey: "secret", appTitle: "Smallcast"
        ).request
        expect(
            gemini?.value(forHTTPHeaderField: "x-goog-api-key") == "secret",
            "Gemini model discovery uses native API-key authentication")
        let openAI = try? AIModelDiscovery.query(
            provider: .openAI, baseURL: URL(string: AIProviderKind.openAI.defaultBaseURL)!,
            apiKey: "secret", appTitle: "Smallcast"
        ).request
        expect(
            openAI?.value(forHTTPHeaderField: "Authorization") == "Bearer secret",
            "OpenAI-compatible discovery uses bearer authentication")
        let local = try? AIModelDiscovery.query(
            provider: .openAICompatible, baseURL: URL(string: "http://localhost:11434/")!,
            apiKey: "", appTitle: "Smallcast"
        ).request
        expect(
            local?.url?.absoluteString == "http://localhost:11434/models",
            "a root endpoint appends one model path separator")
    }

    static func modelCatalogDecodesProviderResponses() {
        let openAI = Data(
            """
            {"data":[
                {"id":"model-a"},
                {"id":"model-b","name":"Model B",
                 "architecture":{"input_modalities":["text","image"]}},
                {"id":"model-a"}
            ]}
            """.utf8)
        let openAIModels = try? AIModelDiscovery.decode(openAI, shape: .openAI)
        expect(
            openAIModels == [
                .init(id: "model-a", name: "model-a"),
                .init(id: "model-b", name: "Model B", inputModalities: ["text", "image"])
            ],
            "OpenAI-compatible model lists are named and deduplicated")
        expect(
            openAIModels?.map(\.acceptsImages) == [nil, true],
            "only a catalog that lists modalities says whether a model takes images")

        let router = AIConnection(
            provider: .openRouter, models: ["model-a", "model-b"], visionModels: ["model-b"])
        expect(
            !router.capabilities(for: "model-a").images
                && router.capabilities(for: "model-b").images
                && router.capabilities(for: "model-a").webSearch,
            "OpenRouter gates images by the catalog and searches for every model")
        let direct = AIConnection(provider: .openAI, models: ["model-a"])
        expect(
            direct.capabilities(for: "model-a").images
                && !direct.capabilities(for: "model-a").webSearch,
            "a vendor API takes images and has no search switch")

        let gemini = Data(
            """
            {"models":[
                {"name":"models/gemini-chat","displayName":"Gemini Chat",\
                 "supportedGenerationMethods":["generateContent"]},
                {"name":"models/gemini-embed","displayName":"Gemini Embed",\
                 "supportedGenerationMethods":["embedContent"]}
            ]}
            """.utf8)
        let geminiModels = try? AIModelDiscovery.decode(gemini, shape: .gemini)
        expect(
            geminiModels == [.init(id: "gemini-chat", name: "Gemini Chat")],
            "Gemini discovery keeps generation models and strips the resource prefix")
    }

    static func modelCatalogSearchesWithoutRenderingEverything() {
        let models = [
            AIModelDiscovery.Model(id: "openai/gpt-small", name: "GPT Small"),
            AIModelDiscovery.Model(id: "anthropic/claude", name: "Claude"),
            AIModelDiscovery.Model(id: "openai/gpt-large", name: "GPT Large"),
            AIModelDiscovery.Model(id: "google/gemini", name: "Gemini")
        ]
        expect(
            AIModelDiscovery.search(models, query: "").isEmpty,
            "an empty search never renders the complete provider catalog")
        expect(
            AIModelDiscovery.search(models, query: "openai").map(\.id)
                == ["openai/gpt-small", "openai/gpt-large"],
            "a provider name finds its models in provider order")
        expect(
            AIModelDiscovery.search(models, query: "GPT Large").first?.id
                == "openai/gpt-large",
            "an exact display-name match ranks first")
        expect(
            AIModelDiscovery.search(
                models, query: "gpt", excluding: ["openai/gpt-small"], limit: 1
            ).map(\.id) == ["openai/gpt-large"],
            "search excludes selected models and caps visible results")
    }

    static func endpointPolicyRejectsUnsafeRemoteURLs() {
        expect(
            (try? AIEndpointPolicy.validate("https://example.com/v1")) != nil,
            "remote HTTPS endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://localhost:11434/v1")) != nil,
            "local HTTP endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://127.0.0.1:1234/v1")) != nil,
            "IPv4 loopback endpoints are accepted")
        expect(
            (try? AIEndpointPolicy.validate("http://example.com/v1")) == nil,
            "remote plaintext endpoints are rejected")
        expect(
            (try? AIEndpointPolicy.validate("not a url")) == nil,
            "malformed endpoints are rejected")
        expect(
            (try? AIEndpointPolicy.validate("ftp://localhost/v1")) == nil,
            "a loopback host does not excuse a scheme the transport cannot speak")
        expect(
            (try? AIEndpointPolicy.validate("file:///etc/hosts")) == nil,
            "file URLs are not a provider")
    }

    static func storedKeysDoNotFollowARetargetedConnection() {
        var saved = AIConnection()
        saved.provider = .openAI
        saved.baseURL = "https://api.openai.com/v1"
        expect(
            AIEndpointPolicy.sameDestination(saved, saved),
            "an untouched connection still points where its key was issued")

        var switchedProvider = saved
        switchedProvider.provider = .anthropic
        expect(
            !AIEndpointPolicy.sameDestination(switchedProvider, saved),
            "a new provider is a new destination, so the OpenAI key must not go to Anthropic")

        var switchedURL = saved
        switchedURL.baseURL = "https://gateway.example.com/v1"
        expect(
            !AIEndpointPolicy.sameDestination(switchedURL, saved),
            "a retyped base URL is a new destination, whatever the provider preset still says")

        var renamed = saved
        renamed.name = "Work key"
        renamed.models = ["gpt-5.4-mini"]
        expect(
            AIEndpointPolicy.sameDestination(renamed, saved),
            "editing a label or the model list is not a retarget and keeps the saved key")
    }

    static func sseFramesSurviveSplits() {
        var parser = SSEParser()
        expect(parser.feed(Data("data: hel".utf8)).isEmpty, "a partial SSE frame waits")
        expect(
            parser.feed(Data("lo\n\ndata: world\r\n\r\n".utf8)) == ["hello", "world"],
            "split LF and CRLF frames are reassembled")
        expect(
            parser.feed(Data(": keepalive\n\ndata: final".utf8)).isEmpty,
            "comments are ignored and a final unterminated frame waits")
        expect(parser.finish() == ["final"], "finish flushes the final frame")
    }

    static func openAIAndAnthropicStreamsDecode() {
        var openAI = AIStreamDecoder(shape: .openAICompatible)
        let openAIData = Data(
            """
            data: {"choices":[{"delta":{"reasoning":"working"}}]}

            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}

            data: [DONE]

            """.utf8)
        var events = (try? openAI.feed(openAIData)) ?? []
        events += (try? openAI.finish()) ?? []
        expect(events.contains(.thinking), "reasoning is surfaced as state, not answer text")
        expect(events.contains(.text("Hello")), "OpenAI-compatible text is decoded")
        expect(
            events.contains(.usage(AIUsage(inputTokens: 3, outputTokens: 2))),
            "OpenAI-compatible usage is decoded")
        expect(events.last == .finished, "the OpenAI done marker terminates the stream")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let anthropicData = Data(
            """
            data: {"type":"message_start","message":{"usage":{"input_tokens":4}}}

            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}

            data: {"type":"message_delta","usage":{"output_tokens":1}}

            data: {"type":"message_stop"}

            """.utf8)
        var anthropicEvents = (try? anthropic.feed(anthropicData)) ?? []
        anthropicEvents += (try? anthropic.finish()) ?? []
        expect(anthropicEvents.contains(.text("Hi")), "Anthropic text is decoded")
        expect(
            anthropicEvents.contains(.usage(AIUsage(inputTokens: 4, outputTokens: 1))),
            "Anthropic usage accumulates across events")
        expect(anthropicEvents.last == .finished, "Anthropic message_stop terminates the stream")
    }

    /// Real OpenRouter captures, with the reasoning ones proving thought never leaks into text.
    static func capturedStreamsDecodeHoweverTheyArrive() {
        let captures: [(file: String, text: String?, reasons: Bool)] = [
            ("openrouter-plain", "1, 2, 3.", false),
            ("openrouter-gemma", nil, false),
            ("openrouter-nemotron-reasoning", nil, true),
            ("openrouter-cohere-reasoning", nil, true)
        ]
        for capture in captures {
            guard let data = FileManager.default.contents(atPath: "Tests/ai-fixtures/\(capture.file).txt")
            else {
                expect(false, "\(capture.file) fixture is readable")
                continue
            }
            let whole = decodeAll(data, slice: data.count)
            let sliced = decodeAll(data, slice: 7)
            expect(whole == sliced, "\(capture.file) decodes the same in 7-byte slices")
            let text = whole.compactMap { event -> String? in
                if case .text(let text) = event { return text }
                return nil
            }.joined()
            if let expected = capture.text {
                expect(text == expected, "\(capture.file) yields exactly its answer text")
            } else {
                expect(!text.isEmpty, "\(capture.file) yields answer text")
            }
            expect(
                whole.contains(.thinking) == capture.reasons,
                "\(capture.file) surfaces thinking only when the model reasoned")
            expect(whole.last == .finished, "\(capture.file) ends on the done marker")
            expect(
                whole.contains {
                    if case .usage(let usage) = $0 { return usage.totalTokens != nil } else { return false }
                },
                "\(capture.file) reports final usage")
        }
    }

    private static func decodeAll(_ data: Data, slice: Int) -> [AIStreamEvent] {
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        var events: [AIStreamEvent] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + slice, data.count)
            events += (try? decoder.feed(data[offset..<end])) ?? []
            offset = end
        }
        events += (try? decoder.finish()) ?? []
        return events
    }

    static func brokenStreamsFailLoudly() {
        var decoder = AIStreamDecoder(shape: .openAICompatible)
        let failure = Data(
            """
            data: {"choices":[{"delta":{"content":"Par"}}]}

            data: {"error":{"message":"Provider returned error","code":502}}

            data: {"choices":[{"delta":{"content":"never"}}]}

            """.utf8)
        var events: [AIStreamEvent] = []
        var thrown: Error?
        do { events = try decoder.feed(failure) } catch { thrown = error }
        expect(
            thrown as? AIProviderError == .responseFailed("Provider returned error"),
            "a mid-stream error payload fails with the provider's message")
        expect(decoder.isTerminal, "a mid-stream error ends the stream")
        expect(events.isEmpty, "nothing after the error is decoded")

        var malformed = AIStreamDecoder(shape: .openAICompatible)
        let garbage = Data("data: {not json\n\n".utf8)
        expect(
            (try? malformed.feed(garbage)) == nil,
            "unparseable JSON is rejected rather than skipped")
        expect(malformed.isTerminal, "a malformed frame ends the stream")

        var anthropic = AIStreamDecoder(shape: .anthropic)
        let rejected = Data(
            "data: {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}\n\n".utf8)
        var anthropicError: Error?
        do { _ = try anthropic.feed(rejected) } catch { anthropicError = error }
        expect(
            anthropicError as? AIProviderError
                == .responseFailed("API key rejected — check it in Settings."),
            "an Anthropic error event names the cause without echoing the key")

        var silent = AIStreamDecoder(shape: .openAICompatible)
        let truncated = Data("data: {\"choices\":[{\"delta\":{\"content\":\"half\"}}]}\n\n".utf8)
        let partial = (try? silent.feed(truncated)) ?? []
        expect(partial == [.text("half")], "text before a cut-off is still delivered")
        expect(!silent.isTerminal, "a stream without a done marker stays open for the caller to fail")
    }

    static func brandsResolveFromModelIDs() {
        let expected: [(String, AIBrand?)] = [
            ("openai/gpt-oss-20b", .openAI), ("o4-mini", .openAI), ("o3", .openAI),
            ("anthropic/claude-sonnet-4", .claude), ("google/gemma-3-27b-it", .gemini),
            ("x-ai/grok-4", .x), ("deepseek/deepseek-r1", .deepSeek), ("qwen/qwq-32b", .qwen),
            ("mistralai/codestral-2501", .mistral), ("meta-llama/llama-3.3-70b", .meta),
            ("moonshotai/kimi-k2", .kimi), ("minimax/minimax-m1", .miniMax),
            ("perplexity/sonar-pro", .perplexity), ("z-ai/glm-4.5", .zai),
            ("openrouter/auto", .openRouter), ("cohere/command-r", nil), ("o10", nil)
        ]
        for (model, brand) in expected {
            expect(
                AIBrand.resolve(model: model) == brand, "\(model) resolves to \(String(describing: brand))")
        }
        expect(
            AIBrand.resolve(provider: .anthropic, model: "whatever") == .claude,
            "a vendor endpoint names its brand regardless of the model id")
        expect(
            AIBrand.resolve(provider: .openAICompatible, model: "deepseek-chat") == .deepSeek,
            "a compatible endpoint resolves the brand from the model id")
    }

    static func codexProtocolFramesRoundTrip() {
        let request = try? CodexAppServerProtocol.request(
            id: 7, method: "account/read", params: ["refreshToken": false])
        let requestObject = request.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        expect((requestObject?["id"] as? Int) == 7, "Codex requests keep numeric IDs")
        expect(
            requestObject?["method"] as? String == "account/read",
            "Codex requests keep their method")

        let response = Data("{\"id\":7,\"result\":{\"ok\":true}}".utf8)
        if case .response(let id, let result) = CodexAppServerProtocol.parse(response) {
            expect(id == 7, "Codex responses route to the pending request")
            expect(result["ok"]?.boolValue == true, "Codex response values preserve booleans")
        } else {
            expect(false, "a valid Codex response parses")
        }
    }

    static func settingsPersistAndRepairSelections() {
        let suite = "AIProviderTests.persistence"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let firstID = UUID()
        let secondID = UUID()

        var first = AIConnection(
            id: firstID, name: "  Work  ", provider: .openRouter,
            models: [" model-a ", "model-a", "model-b"])
        first.baseURL = " https://openrouter.ai/api/v1 "
        let store = AISettingsStore(defaults: defaults)
        store.save(first)
        store.save(
            AIConnection(id: secondID, provider: .gemini, models: ["gemini-model"]))
        expect(store.connections.first?.name == "Work", "connection names are normalized")
        expect(
            store.connections.first?.models == ["model-a", "model-b"],
            "models are trimmed and deduplicated")
        expect(
            store.defaultModel == .api(connection: firstID, model: "model-a"),
            "the first saved model becomes the default")
        store.select(.api(connection: firstID, model: "model-b"))

        let reopened = AISettingsStore(defaults: defaults)
        expect(reopened.connections == store.connections, "connection metadata survives a restart")
        expect(reopened.defaultModel == store.defaultModel, "the default model survives a restart")
        reopened.removeConnection(id: firstID)
        expect(
            reopened.defaultModel == .api(connection: secondID, model: "gemini-model"),
            "removing the default connection falls forward to another API model")
    }

    static func subscriptionSelectionsReconcile() {
        let suite = "AIProviderTests.subscription"
        let defaults = isolatedDefaults(suite)
        defer { discardSuite(suite, defaults) }
        let store = AISettingsStore(defaults: defaults)
        let model = ChatGPTSubscription.Model(
            id: "gpt", name: "GPT",
            efforts: [
                .init(id: "low", detail: nil), .init(id: "high", detail: nil)
            ], defaultEffort: "high", isDefault: true)
        store.select(.chatGPT(model: "gpt", effort: "missing"))
        store.reconcile(chatGPTModels: [model], isSignedOut: false)
        expect(
            store.defaultModel == .chatGPT(model: "gpt", effort: "high"),
            "a removed reasoning tier falls back to the model default")
        store.reconcile(chatGPTModels: [], isSignedOut: true)
        expect(store.defaultModel == nil, "signing out clears an unusable subscription default")
    }
}

/// `removePersistentDomain` only empties the domain; cfprefsd still leaves the plist on disk.
private func discardSuite(_ name: String, _ defaults: UserDefaults) {
    defaults.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    CFPreferencesAppSynchronize(name as CFString)
    try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(name).plist"))
}

/// A fixed suite name stops cfprefsd accumulating a plist per run; the domain is cleared at both ends.
private func isolatedDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
