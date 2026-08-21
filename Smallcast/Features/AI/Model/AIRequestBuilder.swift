import Foundation

/// Turns a config and a transcript into one HTTP request. Pure: no session, no clock, no Keychain,
/// so `ai-test` drives the shipped builder rather than a copy.
enum AIRequestBuilder {
    struct Request: Equatable, Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    enum Failure: Error, Equatable {
        case unusableEndpoint
        case unencodableBody
    }

    static func chat(config: AIProviderConfig, messages: [AIMessage]) throws -> Request {
        guard let url = AIProviderConfig.endpoint(baseURL: config.baseURL, path: config.provider.chatPath)
        else { throw Failure.unusableEndpoint }

        var turns: [[String: String]] = []
        let system = config.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { turns.append(["role": "system", "content": system]) }
        turns += messages.map { ["role": $0.role.rawValue, "content": $0.text] }

        let payload: [String: Any] = ["model": config.model, "stream": true, "messages": turns]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw Failure.unencodableBody
        }

        var headers = ["Content-Type": "application/json", "Accept": accept(config.provider)]
        if let key = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            headers["Authorization"] = "Bearer " + key
        }
        return Request(url: url, headers: headers, body: body)
    }

    private static func accept(_ provider: AIProvider) -> String {
        switch provider.framing {
        case .serverSentEvents: return "text/event-stream"
        case .newlineDelimitedJSON: return "application/x-ndjson"
        }
    }
}
