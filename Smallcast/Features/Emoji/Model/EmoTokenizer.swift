// Ported from desert-ant-core `Sources/Emo/Tokenizer.swift` (v3.2.0), © 2026 Desert Ant Labs B.V.
// SPDX-License-Identifier: LicenseRef-DAL-Source-Available-1.0 — see NOTICE.md.
import Foundation

/// The hashed n-gram stream of Emo's classifier: word and character grams, split by script.
enum EmoNGramEncoder {
    struct Features: Equatable, Sendable {
        /// `count × hashes` bucket indices, one row per feature.
        let buckets: [[Int32]]
        let signs: [[Float]]
        let importance: [Int32]

        var count: Int { importance.count }
    }

    static func encode(
        _ text: String, buckets bucketCount: UInt32, hashes: Int, importance importanceCount: UInt32,
        maxFeatures: Int
    ) -> Features {
        let grams = Array(features(of: text).prefix(maxFeatures))
        var buckets: [[Int32]] = []
        var signs: [[Float]] = []
        var importance: [Int32] = []
        buckets.reserveCapacity(grams.count)
        signs.reserveCapacity(grams.count)
        importance.reserveCapacity(grams.count)
        for gram in grams {
            var row = [Int32](repeating: 0, count: hashes)
            var signRow = [Float](repeating: 0, count: hashes)
            for k in 0..<hashes {
                let hash = fnv64(gram, seed: bucketSeeds[k])
                row[k] = Int32(hash % UInt64(bucketCount))
                signRow[k] = ((hash >> 63) & 1) == 1 ? 1.0 : -1.0
            }
            buckets.append(row)
            signs.append(signRow)
            importance.append(Int32(fnv64(gram, seed: importanceSeed) % UInt64(importanceCount)))
        }
        return Features(buckets: buckets, signs: signs, importance: importance)
    }

    static func fnv64(_ text: String, seed: UInt64) -> UInt64 {
        var hash = (0xCBF2_9CE4_8422_2325 as UInt64) ^ seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    private static let bucketSeeds: [UInt64] = [
        0x9E37_79B9_7F4A_7C15, 0xC2B2_AE3D_27D4_EB4F, 0x1656_67B1_9E37_79F9,
        0x27D4_EB2F_1656_67C5, 0x85EB_CA77_C2B2_AE63
    ]
    private static let importanceSeed: UInt64 = 0xFF51_AFD7_ED55_8CCD
    private static let alphabeticGrams = 3...5
    private static let cjkGrams = 1...2
    private static let jamoGrams = 2...4
    private static let southeastAsianGrams = 2...4
    private static let indicClusterGrams = 2...3

    private static func features(of text: String) -> [String] {
        var out: [String] = []
        for run in tokens(of: normalize(text)) {
            if run.contains(where: isSoutheastAsian) {
                out += grams(run, southeastAsianGrams, tag: "s:")
            } else if run.contains(where: isIndic) {
                let clusters = clusters(of: run)
                out.append("a:" + string(run))
                out += clusterGrams(clusters, 1...1, tag: "k:")
                out += clusterGrams([["<"]] + clusters + [[">"]], indicClusterGrams, tag: "k:")
            } else if run.contains(where: isCJK) {
                for scalar in run where isHangul(scalar) {
                    out += grams(jamo(of: scalar), jamoGrams, tag: "j:")
                }
                out += grams(run, cjkGrams, tag: "c:")
            } else {
                out.append("w:" + string(run))
                out += grams(["<"] + run + [">"], alphabeticGrams, tag: "g:")
            }
        }
        return out.isEmpty ? ["w:\u{0}"] : out
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private static func grams(
        _ scalars: [Unicode.Scalar], _ sizes: ClosedRange<Int>, tag: String
    ) -> [String] {
        var out: [String] = []
        for n in sizes where scalars.count >= n {
            for i in 0...(scalars.count - n) { out.append(tag + string(Array(scalars[i..<(i + n)]))) }
        }
        return out
    }

    private static func clusterGrams(
        _ clusters: [[Unicode.Scalar]], _ sizes: ClosedRange<Int>, tag: String
    ) -> [String] {
        var out: [String] = []
        for n in sizes where clusters.count >= n {
            for i in 0...(clusters.count - n) {
                out.append(tag + string(clusters[i..<(i + n)].flatMap { $0 }))
            }
        }
        return out
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func tokens(of text: String) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                out.append(current)
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func clusters(of scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in scalars {
            if current.isEmpty {
                current = [scalar]
                continue
            }
            let previous = current[current.count - 1].value
            let virama =
                (0x0900...0x0DFF).contains(previous)
                && ((previous & 0xFF) == 0x4D || (previous & 0xFF) == 0xCD)
            if isMark(scalar) || virama {
                current.append(scalar)
            } else {
                out.append(current)
                current = [scalar]
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func jamo(of scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        guard isHangul(scalar) else { return [scalar] }
        let index = Int(scalar.value) - 0xAC00
        var out = [
            Unicode.Scalar(UInt32(0x1100 + index / 588))!,
            Unicode.Scalar(UInt32(0x1161 + (index % 588) / 28))!
        ]
        if index % 28 != 0 { out.append(Unicode.Scalar(UInt32(0x11A7 + index % 28))!) }
        return out
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .nonspacingMark, .spacingMark, .enclosingMark,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.canonicalCombiningClass != .notReordered { return true }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7A3).contains(scalar.value)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value)
            || (0x2_0000...0x2_A6DF).contains(value) || (0xF900...0xFAFF).contains(value)
            || (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value)
            || isHangul(scalar)
    }

    private static func isSoutheastAsian(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x0E00...0x0EFF).contains(value) || (0x1000...0x109F).contains(value)
            || (0x1780...0x17FF).contains(value)
    }

    private static func isIndic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0900...0x0DFF).contains(scalar.value)
    }
}

/// Emo's pruned-unigram tokenizer: a Viterbi segmentation over the `EMTK` vocabulary container.
struct EmoSemanticTokenizer: Sendable {
    private let scores: [Float]
    private let vocabulary: EmoVocabularyIndex
    private let unknownID: Int32
    private let unknownScore: Double
    private let maxPieceLength: Int

    init?(bytes: [UInt8]) {
        guard bytes.count >= 14, bytes[0] == 0x45, bytes[1] == 0x4D, bytes[2] == 0x54, bytes[3] == 0x4B
        else { return nil }
        var offset = 6
        func u32() -> UInt32 {
            let value =
                UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return value
        }
        unknownID = Int32(bitPattern: u32())
        let count = Int(u32())
        var scores: [Float] = []
        scores.reserveCapacity(count)
        for _ in 0..<count { scores.append(Float(bitPattern: u32())) }
        var lengths: [Int] = []
        lengths.reserveCapacity(count)
        for _ in 0..<count {
            lengths.append(Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
            offset += 2
        }
        guard bytes.count >= offset + lengths.reduce(0, +), bytes.count <= Int(Int32.max) else {
            return nil
        }
        var bounds: [Int32] = []
        bounds.reserveCapacity(count + 1)
        var longest = 1
        for length in lengths {
            bounds.append(Int32(offset))
            var scalars = 0
            for byte in bytes[offset..<(offset + length)] where byte & 0xC0 != 0x80 { scalars += 1 }
            longest = max(longest, scalars)
            offset += length
        }
        bounds.append(Int32(offset))
        guard unknownID >= 0, Int(unknownID) < count,
            let vocabulary = EmoVocabularyIndex(image: bytes, bounds: bounds)
        else { return nil }
        self.scores = scores
        self.vocabulary = vocabulary
        maxPieceLength = min(longest, 24)
        unknownScore = Double(scores[Int(unknownID)])
    }

    func encode(_ text: String) -> [Int32] {
        let separator: Character = "\u{2581}"
        let lowered = text.lowercased().precomposedStringWithCompatibilityMapping
        let normalized = String([separator] + lowered.map { $0 == " " ? separator : $0 })
        let scalars = Array(normalized.unicodeScalars)
        let count = scalars.count
        if count == 0 { return [] }
        let utf8 = Array(normalized.utf8)
        var byteOffset = [Int](repeating: 0, count: count + 1)
        for (i, scalar) in scalars.enumerated() {
            byteOffset[i + 1] = byteOffset[i] + Self.utf8Width(scalar)
        }

        return utf8.withUnsafeBufferPointer { text -> [Int32] in
            vocabulary.withLookup { lookup -> [Int32] in
                var best = [Double](repeating: -1e18, count: count + 1)
                best[0] = 0
                var backPosition = [Int](repeating: -1, count: count + 1)
                var backID = [Int32](repeating: -1, count: count + 1)
                for i in 1...count {
                    for j in max(0, i - maxPieceLength)..<i {
                        let piece = UnsafeBufferPointer(rebasing: text[byteOffset[j]..<byteOffset[i]])
                        guard let id = lookup.id(of: piece) else { continue }
                        let score = best[j] + Double(scores[id])
                        if score > best[i] {
                            best[i] = score
                            backPosition[i] = j
                            backID[i] = Int32(id)
                        }
                    }
                    let unknown = best[i - 1] + unknownScore
                    if unknown > best[i] {
                        best[i] = unknown
                        backPosition[i] = i - 1
                        backID[i] = unknownID
                    }
                }
                var ids: [Int32] = []
                var i = count
                while i > 0 {
                    ids.append(backID[i])
                    i = backPosition[i]
                }
                return ids.reversed()
            }
        }
    }

    private static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case ..<0x80: return 1
        case ..<0x800: return 2
        case ..<0x1_0000: return 3
        default: return 4
        }
    }
}

/// Vocabulary keyed on a piece's UTF-8 bytes: `String` keys would merge canonically-equal pieces.
struct EmoVocabularyIndex: Sendable {
    private let image: [UInt8]
    private let bounds: [Int32]
    private let table: [Int32]
    private let mask: Int

    init?(image: [UInt8], bounds: [Int32]) {
        let count = bounds.count - 1
        guard count > 0 else { return nil }
        var capacity = 16
        while capacity < count * 2 { capacity <<= 1 }
        var slots = [Int32](repeating: -1, count: capacity)
        let mask = capacity - 1

        let duplicate = image.withUnsafeBufferPointer { bytes -> Bool in
            for id in 0..<count {
                let piece = UnsafeBufferPointer(rebasing: bytes[Int(bounds[id])..<Int(bounds[id + 1])])
                var slot = Self.hash(piece) & mask
                while slots[slot] >= 0 {
                    let other = Int(slots[slot])
                    let range = Int(bounds[other])..<Int(bounds[other + 1])
                    if range.count == piece.count,
                        UnsafeBufferPointer(rebasing: bytes[range]).elementsEqual(piece)
                    {
                        return true
                    }
                    slot = (slot + 1) & mask
                }
                slots[slot] = Int32(id)
            }
            return false
        }
        guard !duplicate else { return nil }

        self.image = image
        self.bounds = bounds
        table = slots
        self.mask = mask
    }

    func withLookup<R>(_ body: (Lookup) -> R) -> R {
        image.withUnsafeBufferPointer { image in
            bounds.withUnsafeBufferPointer { bounds in
                table.withUnsafeBufferPointer { table in
                    body(Lookup(image: image, bounds: bounds, table: table, mask: mask))
                }
            }
        }
    }

    struct Lookup {
        fileprivate let image: UnsafeBufferPointer<UInt8>
        fileprivate let bounds: UnsafeBufferPointer<Int32>
        fileprivate let table: UnsafeBufferPointer<Int32>
        fileprivate let mask: Int

        func id(of query: UnsafeBufferPointer<UInt8>) -> Int? {
            var slot = EmoVocabularyIndex.hash(query) & mask
            while true {
                let id = Int(table[slot])
                if id < 0 { return nil }
                let low = Int(bounds[id])
                let high = Int(bounds[id + 1])
                if high - low == query.count,
                    UnsafeBufferPointer(rebasing: image[low..<high]).elementsEqual(query)
                {
                    return id
                }
                slot = (slot + 1) & mask
            }
        }
    }

    fileprivate static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(truncatingIfNeeded: hash) & Int.max
    }
}
