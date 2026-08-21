import Foundation

/// Incremental reply decoder. Buffers **bytes**, not text: a chunk boundary can land in the middle
/// of a multi-byte scalar, and decoding each half on its own loses the character.
struct AIStreamDecoder {
    enum Event: Equatable, Sendable {
        case delta(String)
        /// A reasoning model's private thinking. Reported so the palette can say it is working, and
        /// deliberately never appended to the answer.
        case reasoning
        case done
        case failed(String)
    }

    private static let dataPrefix = "data:"
    private static let sentinel = "[DONE]"
    private static let newline: UInt8 = 0x0A

    private let framing: AIStreamFraming
    private var buffer = Data()

    init(provider: AIProvider) {
        framing = provider.framing
    }

    /// One chunk in, whatever whole lines it completed out. A line without its newline is held.
    mutating func consume(_ data: Data) -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while let index = buffer.firstIndex(of: Self.newline) {
            let line = Data(buffer[buffer.startIndex..<index])
            buffer = Data(buffer[buffer.index(after: index)...])
            events += self.events(in: line)
        }
        return events
    }

    /// The body ended: a server that omits the trailing newline still gets its last line read.
    mutating func finish() -> [Event] {
        let remainder = buffer
        buffer = Data()
        return events(in: remainder)
    }

    /// A whole non-streamed body — what a 4xx answers with, before any framing applies.
    static func message(in body: String) -> String? {
        errorMessage(in: body)
    }

    private func events(in line: Data) -> [Event] {
        guard let text = String(data: line, encoding: .utf8) else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        switch framing {
        case .serverSentEvents: return serverSentEvents(trimmed)
        case .newlineDelimitedJSON: return jsonEvents(trimmed)
        }
    }

    private func serverSentEvents(_ line: String) -> [Event] {
        guard line.hasPrefix(Self.dataPrefix) else {
            // A comment or `event:` line carries nothing; an unframed body is an error payload.
            return line.hasPrefix(":") ? [] : (Self.errorMessage(in: line).map { [.failed($0)] } ?? [])
        }
        let payload = String(line.dropFirst(Self.dataPrefix.count)).trimmingCharacters(in: .whitespaces)
        guard payload != Self.sentinel else { return [.done] }
        return jsonEvents(payload)
    }

    private func jsonEvents(_ payload: String) -> [Event] {
        guard let object = Self.object(in: payload) else { return [] }
        if let message = Self.errorMessage(in: object) { return [.failed(message)] }
        var events: [Event] = []
        if let delta = Self.deltaText(in: object), !delta.isEmpty {
            events.append(.delta(delta))
        } else if Self.isReasoning(object) {
            events.append(.reasoning)
        }
        // Ollama marks its own last chunk; OpenAI sends `[DONE]` on a line of its own instead.
        if object["done"] as? Bool == true { events.append(.done) }
        return events
    }

    /// `choices[0].delta.content` for OpenAI, `message.content` for Ollama — one of the two exists.
    private static func deltaText(in object: [String: Any]) -> String? {
        if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
                return content
            }
            // Some OpenAI-compatible servers stream whole messages rather than deltas.
            if let message = first["message"] as? [String: Any],
                let content = message["content"] as? String
            {
                return content
            }
        }
        if let message = object["message"] as? [String: Any],
            let content = message["content"] as? String
        {
            return content
        }
        return nil
    }

    /// A chunk carrying only `reasoning_content`. LM Studio streams a long run of these before the
    /// first word of the answer, and a bare spinner for that whole time reads as a hang.
    private static func isReasoning(_ object: [String: Any]) -> Bool {
        let choice = (object["choices"] as? [[String: Any]])?.first
        for container in [choice?["delta"], choice?["message"], object["message"]] {
            guard let container = container as? [String: Any] else { continue }
            if let text = container["reasoning_content"] as? String, !text.isEmpty { return true }
        }
        return false
    }

    private static func object(in payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func errorMessage(in payload: String) -> String? {
        object(in: payload).flatMap(errorMessage(in:))
    }

    /// Both shapes appear in the wild: a bare string, and an object with a `message`.
    private static func errorMessage(in object: [String: Any]) -> String? {
        if let text = object["error"] as? String { return text }
        guard let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String ?? "The provider reported an error."
    }
}
