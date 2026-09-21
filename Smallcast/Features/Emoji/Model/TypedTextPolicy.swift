import Foundation

/// The rolling record of what was typed, and the phrase the picker should suggest emoji for.
struct TypedTextPolicy: Sendable {
    enum Input: Equatable, Sendable {
        case text(String)
        case deleteBackward
        case reset
        case ignored
    }

    /// Bounded so an afternoon of typing never grows the record past one screen of text.
    static let capacity = 240
    /// The model is tuned for short phrases, so only the tail of a long sentence is offered.
    static let phraseWordLimit = 16
    /// A record older than this describes a sentence the reader has moved on from.
    static let idleTimeout: TimeInterval = 60

    private(set) var buffer = ""
    private var lastInput: Date?

    /// Modifier chords, navigation keys and Secure Event Input all make the record stale.
    static func classify(
        text: String?, isSynthetic: Bool, secureEventInputEnabled: Bool, isKeyDown: Bool,
        hasCommandOrControl: Bool, isNavigationKey: Bool, isDeleteBackward: Bool
    ) -> Input {
        if isSynthetic { return .ignored }
        if secureEventInputEnabled || hasCommandOrControl || isNavigationKey { return .reset }
        guard isKeyDown else { return .ignored }
        if isDeleteBackward { return .deleteBackward }
        guard let text else { return .reset }
        return .text(text)
    }

    mutating func process(_ input: Input, at now: Date) {
        if let lastInput, now.timeIntervalSince(lastInput) > Self.idleTimeout { buffer = "" }
        switch input {
        case .ignored:
            return
        case .reset:
            buffer = ""
        case .deleteBackward:
            if !buffer.isEmpty { buffer.removeLast() }
        case .text(let text):
            buffer.append(text)
            if buffer.count > Self.capacity {
                buffer.removeFirst(buffer.count - Self.capacity)
            }
        }
        lastInput = now
    }

    mutating func reset() {
        buffer = ""
        lastInput = nil
    }

    /// The last sentence typed, at most `phraseWordLimit` words; empty when nothing usable remains.
    var phrase: String {
        let sentences = buffer.split(whereSeparator: Self.isSentenceBreak)
        guard let last = sentences.last(where: { $0.contains(where: { !$0.isWhitespace }) }) else {
            return ""
        }
        let words = last.split(whereSeparator: \.isWhitespace)
        return words.suffix(Self.phraseWordLimit).joined(separator: " ")
    }

    private static func isSentenceBreak(_ character: Character) -> Bool {
        character.isNewline || ".!?;。！？".contains(character)
    }
}
