import Foundation

/// Whisper's byte-level BPE vocabulary, read from the checkpoint's `tokenizer.json`.
struct WhisperVocabulary: Sendable {
    private let tokens: [Int: String]
    private let ids: [String: Int]

    let endOfText: Int
    let startOfTranscript: Int
    let transcribe: Int
    let translate: Int
    let noTimestamps: Int
    let noSpeech: Int
    /// `<|0.00|>`; every id at or past it is a timestamp, and every special token sits below it.
    let firstTimestamp: Int
    /// The first id that is not plain text: `<|endoftext|>`.
    let firstSpecial: Int

    init(tokenizerJSON data: Data) throws {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? [String: Any],
            let vocab = model["vocab"] as? [String: Int]
        else { throw VocabularyError.unreadable }
        var tokens: [Int: String] = [:]
        var ids: [String: Int] = [:]
        tokens.reserveCapacity(vocab.count + 1_600)
        for (token, id) in vocab {
            tokens[id] = token
            ids[token] = id
        }
        for added in root["added_tokens"] as? [[String: Any]] ?? [] {
            guard let id = added["id"] as? Int, let content = added["content"] as? String else {
                continue
            }
            tokens[id] = content
            ids[content] = id
        }
        guard
            let endOfText = ids["<|endoftext|>"], let sot = ids["<|startoftranscript|>"],
            let transcribe = ids["<|transcribe|>"], let translate = ids["<|translate|>"],
            let noTimestamps = ids["<|notimestamps|>"],
            let firstTimestamp = ids["<|0.00|>"]
        else { throw VocabularyError.unreadable }
        self.tokens = tokens
        self.ids = ids
        self.endOfText = endOfText
        self.startOfTranscript = sot
        self.transcribe = transcribe
        self.translate = translate
        self.noTimestamps = noTimestamps
        self.noSpeech = ids["<|nospeech|>"] ?? ids["<|nocaptions|>"] ?? endOfText
        self.firstTimestamp = firstTimestamp
        self.firstSpecial = endOfText
    }

    var count: Int { tokens.count }

    /// `<|fr|>` for `fr`; nil for a language the checkpoint does not know.
    func languageToken(_ code: String) -> Int? {
        ids["<|\(code)|>"]
    }

    /// The id of one token as spelled in the vocabulary, `ĠHello` for a word after a space.
    func id(ofToken token: String) -> Int? { ids[token] }

    /// Every `<|xx|>` id: they sit between start-of-transcript and the two task tokens.
    var languageTokens: [Int: String] {
        var result: [Int: String] = [:]
        for id in (startOfTranscript + 1)..<min(transcribe, translate) {
            guard let token = tokens[id], token.hasPrefix("<|"), token.hasSuffix("|>") else {
                continue
            }
            result[id] = String(token.dropFirst(2).dropLast(2))
        }
        return result
    }

    /// Text tokens only; specials and timestamps are dropped, bytes are reassembled.
    func text(for ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids where id < firstSpecial {
            guard let token = tokens[id] else { continue }
            for scalar in token.unicodeScalars {
                if let byte = Self.unicodeToByte[scalar] { bytes.append(byte) }
            }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// GPT-2's byte→printable-scalar table, inverted: the 256 bytes map onto 188 printable ASCII and
    /// Latin-1 scalars, and the rest onto U+0100 upward in order.
    private static let unicodeToByte: [Unicode.Scalar: UInt8] = {
        var printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var table: [Unicode.Scalar: UInt8] = [:]
        for byte in printable {
            table[Unicode.Scalar(UInt8(byte))] = UInt8(byte)
        }
        var next = 256
        for byte in 0..<256 where !printable.contains(byte) {
            table[Unicode.Scalar(UInt32(next))!] = UInt8(byte)
            next += 1
        }
        printable.removeAll()
        return table
    }()
}
