import Foundation

/// The one network path the AI feature has. On its own `.ephemeral`, `urlCache = nil` session, never
/// `URLSession.shared`, so no prompt or answer is ever written to a cache Smallcast shares.
enum AIClient {
    enum Event: Sendable {
        case delta(String)
        /// A reasoning model is thinking; nothing to show yet, but something to say.
        case thinking
        case failed(String)
    }

    /// Long enough for a slow first token on a local model, short enough to give up on a dead host.
    private static let requestTimeout: TimeInterval = 180
    private static let errorBodyLimit = 4000

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: config)
    }()

    /// Cancelling the consuming task cancels the request: `onTermination` is the only stop signal.
    nonisolated static func stream(
        config: AIProviderConfig, messages: [AIMessage]
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(config: config, messages: messages, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What the server says it can serve, for the Settings pane's model menu. Empty on any failure:
    /// the field stays free text, so a listing that doesn't answer costs nothing.
    nonisolated static func models(config: AIProviderConfig) async -> [String] {
        guard
            let url = AIProviderConfig.endpoint(
                baseURL: config.baseURL, path: config.provider.modelsPath)
        else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return AIModelList.decode(data, provider: config.provider)
    }

    /// Whether the endpoint answers at all, for the settings pane's Test Connection button. It
    /// returns on the **first** event of any kind and lets the stream be cancelled: a reasoning model
    /// can think for minutes before its first word, and waiting for that would report a working
    /// server as broken. A thinking chunk is the server answering.
    nonisolated static func probe(config: AIProviderConfig) async -> String? {
        let probe = AIMessage(role: .user, text: "Say OK.", createdAt: Date())
        for await event in stream(config: config, messages: [probe]) {
            if case .failed(let message) = event { return message }
            return nil
        }
        return "The provider closed the connection without answering."
    }

    private nonisolated static func run(
        config: AIProviderConfig, messages: [AIMessage],
        into continuation: AsyncStream<Event>.Continuation
    ) async {
        guard let request = try? AIRequestBuilder.chat(config: config, messages: messages) else {
            continuation.yield(.failed("The provider's address or model is incomplete."))
            return
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                continuation.yield(.failed("The provider answered with something that isn’t HTTP."))
                return
            }
            guard http.statusCode == 200 else {
                continuation.yield(.failed(await failure(status: http.statusCode, bytes: bytes)))
                return
            }
            var decoder = AIStreamDecoder(provider: config.provider)
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return }
                for event in decoder.consume(Data((line + "\n").utf8)) {
                    guard emit(event, into: continuation) else { return }
                }
            }
            for event in decoder.finish() {
                guard emit(event, into: continuation) else { return }
            }
        } catch is CancellationError {
            return
        } catch {
            continuation.yield(.failed(error.localizedDescription))
        }
    }

    /// False once the stream is over, so the caller stops reading rather than yielding past `.done`.
    private nonisolated static func emit(
        _ event: AIStreamDecoder.Event, into continuation: AsyncStream<Event>.Continuation
    ) -> Bool {
        switch event {
        case .delta(let text):
            continuation.yield(.delta(text))
            return true
        case .reasoning:
            continuation.yield(.thinking)
            return true
        case .failed(let message):
            continuation.yield(.failed(message))
            return false
        case .done:
            return false
        }
    }

    /// The body of a rejected request, read for the message the provider put in it.
    private nonisolated static func failure(
        status: Int, bytes: URLSession.AsyncBytes
    ) async -> String {
        var body = ""
        do {
            for try await line in bytes.lines {
                body += line
                if body.count > errorBodyLimit { break }
            }
        } catch {
            // A truncated error body still describes the status, which is the part that matters.
        }
        if let message = AIStreamDecoder.message(in: body), !message.isEmpty { return message }
        return "The provider rejected the request (HTTP \(status))."
    }
}
