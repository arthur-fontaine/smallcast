import Foundation

/// Token ids back to text for the NeMo models: a JSON vocabulary, or a SentencePiece `.model`.
struct SentencePieceVocabulary: Sendable {
    private let pieces: [Int: String]

    /// U+2581, the marker SentencePiece puts on a piece that starts a word.
    static let wordBoundary = "\u{2581}"

    init(pieces: [Int: String]) {
        self.pieces = pieces
    }

    /// Parakeet ships `{"id": "piece"}`; the 110m and EOU exports ship a plain array.
    init(json data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        if let dictionary = object as? [String: String] {
            var pieces: [Int: String] = [:]
            for (key, piece) in dictionary {
                if let id = Int(key) { pieces[id] = piece }
            }
            self.pieces = pieces
        } else if let array = object as? [String] {
            self.pieces = Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0, $1) })
        } else {
            throw VocabularyError.unreadable
        }
    }

    /// Reads only the `pieces` field of a SentencePiece `ModelProto`, in id order.
    init(sentencePieceModel data: Data) throws {
        var reader = ProtobufReader(data: data)
        var pieces: [Int: String] = [:]
        var index = 0
        while let field = try reader.next() {
            guard field.number == 1, case .bytes(let message) = field.value else { continue }
            var inner = ProtobufReader(data: message)
            var piece: String?
            while let sub = try inner.next() {
                if sub.number == 1, case .bytes(let bytes) = sub.value {
                    piece = String(decoding: bytes, as: UTF8.self)
                }
            }
            if let piece { pieces[index] = piece }
            index += 1
        }
        guard !pieces.isEmpty else { throw VocabularyError.unreadable }
        self.pieces = pieces
    }

    var count: Int { pieces.count }

    func piece(_ id: Int) -> String? { pieces[id] }

    /// The id of an exact piece, for the `<en-US>` language tags.
    func id(ofPiece piece: String) -> Int? {
        pieces.first { $0.value == piece }?.key
    }

    /// Joins pieces into text: `▁` becomes a space, `<0xNN>` bytes are reassembled, tags dropped.
    func text(for ids: [Int]) -> String {
        var out = ""
        var bytes: [UInt8] = []
        func flush() {
            guard !bytes.isEmpty else { return }
            out += String(decoding: bytes, as: UTF8.self)
            bytes.removeAll(keepingCapacity: true)
        }
        for id in ids {
            guard let piece = pieces[id], !piece.isEmpty else { continue }
            if let byte = Self.byteFallback(piece) {
                bytes.append(byte)
                continue
            }
            flush()
            if piece.hasPrefix("<"), piece.hasSuffix(">") { continue }
            out += piece
        }
        flush()
        return
            out
            .replacingOccurrences(of: Self.wordBoundary, with: " ")
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func byteFallback(_ piece: String) -> UInt8? {
        guard piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">") else { return nil }
        return UInt8(piece.dropFirst(3).dropLast(), radix: 16)
    }
}

enum VocabularyError: Error {
    case unreadable
}

/// Just enough protobuf wire format to walk a message's top-level fields.
struct ProtobufReader {
    struct Field {
        let number: Int
        let value: Value
    }

    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed32
        case fixed64
    }

    private let data: Data
    private var offset: Int

    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func next() throws -> Field? {
        guard offset < data.endIndex else { return nil }
        let key = try varint()
        let number = Int(key >> 3)
        switch key & 7 {
        case 0: return Field(number: number, value: .varint(try varint()))
        case 1:
            try advance(8)
            return Field(number: number, value: .fixed64)
        case 2:
            let length = Int(try varint())
            guard length >= 0, offset + length <= data.endIndex else {
                throw VocabularyError.unreadable
            }
            let bytes = data[offset..<offset + length]
            offset += length
            return Field(number: number, value: .bytes(Data(bytes)))
        case 5:
            try advance(4)
            return Field(number: number, value: .fixed32)
        default: throw VocabularyError.unreadable
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard offset + count <= data.endIndex else { throw VocabularyError.unreadable }
        offset += count
    }

    private mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < data.endIndex, shift < 64 else { throw VocabularyError.unreadable }
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }
}
