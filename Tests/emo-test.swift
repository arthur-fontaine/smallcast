// Standalone test for the Emo port and the typed-text record, compiling the shipped sources.
// Set SMALLCAST_EMO_MODEL_DIR to a downloaded model folder to also run the Core ML classifier.
import Foundation

@main
@MainActor
struct EmoTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if !condition {
            print("FAIL: \(label)")
            failures += 1
        }
    }

    /// Golden vectors produced by desert-ant-core's `Tokenizer.swift` (v3.2.0) on these phrases:
    /// feature count, first bucket row, bucket sum, importance sum, semantic ids.
    static let golden: [(String, Int, [Int32], Int, Int, [Int32])] = [
        ("Dentist appointment", 50, [21500, 20866, 16688], 3_471_506, 395_562, [30210, 31248]),
        (
            "réserver un vol pour Tokyo", 56, [17182, 34444, 30098], 3_749_268, 453_372,
            [38485, 41, 1941, 469, 36731]
        ),
        ("犬の散歩", 7, [14340, 30010, 4456], 416_659, 59899, [47085, 132, 33937]),
        ("จองโรงแรม", 21, [14042, 34820, 25038], 1_532_737, 159_273, [3, 16047, 12422]),
        ("한국어 테스트", 20, [2666, 4256, 15526], 1_229_022, 166_902, [2158, 5196, 1585, 30448]),
        ("नमस्ते दुनिया", 22, [11327, 30373, 1947], 1_441_945, 204_459, [1198, 21807, 34288, 12282]),
        (
            "  Pay   MY bills  ", 24, [32369, 14847, 23165], 1_673_842, 180_542,
            [3, 3, 5133, 3, 3, 600, 37875, 3, 3]
        ),
        ("", 1, [19319, 8357, 24515], 52191, 11823, [3]),
        ("ＡＢＣ ﬁ", 11, [4227, 18537, 16975], 792_295, 101_843, [36684, 634])
    ]

    static func main() async throws {
        testNGrams()
        testSyntheticTokenizer()
        testInputs()
        testRanking()
        testTypedText()
        try await testModelIfAvailable()

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("emo-test: all passed")
    }

    static func testNGrams() {
        for (phrase, count, first, sum, importanceSum, _) in golden {
            let features = EmoNGramEncoder.encode(
                phrase, buckets: 44000, hashes: 3, importance: 16000, maxFeatures: 512)
            expect(features.count == count, "\(phrase.debugDescription) yields \(count) features")
            expect(features.buckets.first == first, "\(phrase.debugDescription) first bucket row")
            expect(
                features.buckets.flatMap { $0 }.reduce(0) { $0 &+ Int($1) } == sum,
                "\(phrase.debugDescription) bucket sum")
            expect(
                features.importance.reduce(0) { $0 &+ Int($1) } == importanceSum,
                "\(phrase.debugDescription) importance sum")
            expect(
                features.signs.allSatisfy { $0.allSatisfy { abs($0) == 1 } },
                "\(phrase.debugDescription) signs are ±1")
        }
        let capped = EmoNGramEncoder.encode(
            String(repeating: "abcdefgh ", count: 200), buckets: 44000, hashes: 3, importance: 16000,
            maxFeatures: 512)
        expect(capped.count == 512, "features stop at the window")
    }

    /// An `EMTK` container holding `pieces` with equal scores; id 0 is the unknown piece.
    static func container(_ pieces: [String]) -> [UInt8] {
        var bytes: [UInt8] = Array("EMTK".utf8) + [1, 0]
        func u32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> shift) & 0xFF)) } }
        u32(0)
        u32(UInt32(pieces.count))
        for index in pieces.indices { u32((index == 0 ? Float(-20) : Float(-1)).bitPattern) }
        for piece in pieces {
            let length = piece.utf8.count
            bytes.append(UInt8(length & 0xFF))
            bytes.append(UInt8(length >> 8))
        }
        for piece in pieces { bytes += Array(piece.utf8) }
        return bytes
    }

    static func testSyntheticTokenizer() {
        let pieces = ["<unk>", "\u{2581}pay", "\u{2581}my", "\u{2581}bill", "s", "\u{2581}", "m", "ộ", "t"]
        guard let tokenizer = EmoSemanticTokenizer(bytes: container(pieces)) else {
            expect(false, "synthetic container parses")
            return
        }
        expect(tokenizer.encode("Pay my bills") == [1, 2, 3, 4], "Viterbi picks whole words over pieces")
        expect(tokenizer.encode("") == [5], "empty text is just the leading word separator")
        expect(tokenizer.encode("zz") == [5, 0, 0], "unknown characters fall back to the unknown id")
        expect(
            tokenizer.encode("một") == [5, 6, 7, 8],
            "a byte-distinct piece survives even when canonically equal to another")
        expect(EmoSemanticTokenizer(bytes: Array("nope".utf8)) == nil, "a foreign container is rejected")
        expect(
            EmoSemanticTokenizer(bytes: container(["<unk>", "a", "a"])) == nil,
            "duplicate pieces mark a malformed container")
    }

    static func testInputs() {
        let json = """
            {"labels":["🦷","✈️"],"n_hashes":3,"n_buckets":44000,"n_importance":16000,
             "sem_pad_index":48000,"fmax":512,"smax":64}
            """
        guard let meta = try? EmoMeta(json: Data(json.utf8)),
            let tokenizer = EmoSemanticTokenizer(bytes: container(["<unk>", "\u{2581}hi"]))
        else {
            expect(false, "meta and tokenizer parse")
            return
        }
        let inputs = EmoModelInputs(text: "hi", meta: meta, tokenizer: tokenizer)
        expect(inputs.ngramBuckets.count == 512 * 3, "bucket tensor is fmax × hashes")
        expect(inputs.ngramImportance.count == 512, "importance tensor is fmax")
        expect(inputs.ngramCount == 4, "count is the live feature count")
        expect(inputs.semanticIDs.count == 64 && inputs.semanticMask.count == 64, "semantic window is smax")
        expect(inputs.semanticIDs[0] == 1 && inputs.semanticMask[0] == 1, "the token lands unmasked")
        expect(inputs.semanticIDs[1] == 48000 && inputs.semanticMask[1] == 0, "padding is masked")

        let empty = EmoModelInputs(text: "", meta: meta, tokenizer: tokenizer)
        expect(empty.ngramCount == 1, "an empty phrase still counts its sentinel feature")
        expect(empty.semanticMask[0] == 1 && empty.semanticIDs[0] == 0, "the separator alone is unknown")
    }

    static func testRanking() {
        let ranked = EmoRanking.rank(
            probabilities: [0.1, 0.6, 0.005, 0.3], labels: ["a", "b", "c", "d"], limit: 3,
            minimumConfidence: 0.01)
        expect(ranked.map(\.glyph) == ["b", "d", "a"], "ranking sorts by confidence and drops the floor")
        expect(
            EmoRanking.rank(probabilities: [0.5], labels: ["a", "b"], limit: 8, minimumConfidence: 0)
                .count == 1, "a short probability vector never indexes past its end")
    }

    static func testTypedText() {
        var policy = TypedTextPolicy()
        var now = Date(timeIntervalSince1970: 1000)
        func type(_ text: String) {
            for character in text {
                policy.process(.text(String(character)), at: now)
                now += 0.1
            }
        }
        type("Hello there. Let's grab pizza tonight")
        expect(policy.phrase == "Let's grab pizza tonight", "the phrase is the last sentence")
        policy.process(.deleteBackward, at: now)
        expect(policy.phrase == "Let's grab pizza tonigh", "backspace shortens the record")
        type("t!")
        expect(policy.phrase == "Let's grab pizza tonight", "a terminator alone leaves the sentence")
        policy.process(.reset, at: now)
        expect(policy.phrase.isEmpty, "reset forgets everything")

        type(String(repeating: "word ", count: 30))
        expect(
            policy.phrase.split(separator: " ").count == TypedTextPolicy.phraseWordLimit,
            "a long sentence is cut to its tail")
        expect(policy.buffer.count <= TypedTextPolicy.capacity, "the record is capped")

        policy.process(.reset, at: now)
        type("stale")
        now += TypedTextPolicy.idleTimeout + 1
        type("fresh")
        expect(policy.phrase == "fresh", "an idle gap starts a new record")

        expect(
            TypedTextPolicy.classify(
                text: "a", isSynthetic: true, secureEventInputEnabled: false, isKeyDown: true,
                hasCommandOrControl: false, isNavigationKey: false, isDeleteBackward: false)
                == .ignored, "Smallcast's own keystrokes are ignored")
        expect(
            TypedTextPolicy.classify(
                text: "a", isSynthetic: false, secureEventInputEnabled: true, isKeyDown: true,
                hasCommandOrControl: false, isNavigationKey: false, isDeleteBackward: false)
                == .reset, "secure input resets the record")
        expect(
            TypedTextPolicy.classify(
                text: "v", isSynthetic: false, secureEventInputEnabled: false, isKeyDown: true,
                hasCommandOrControl: true, isNavigationKey: false, isDeleteBackward: false)
                == .reset, "a command chord resets the record")
        expect(
            TypedTextPolicy.classify(
                text: nil, isSynthetic: false, secureEventInputEnabled: false, isKeyDown: false,
                hasCommandOrControl: false, isNavigationKey: false, isDeleteBackward: false)
                == .ignored, "a key-up is ignored")
        expect(
            TypedTextPolicy.classify(
                text: "\u{8}", isSynthetic: false, secureEventInputEnabled: false, isKeyDown: true,
                hasCommandOrControl: false, isNavigationKey: false, isDeleteBackward: true)
                == .deleteBackward, "delete is a backspace")
    }

    /// The README's own examples, top-1, against the real model when one is on disk.
    static func testModelIfAvailable() async throws {
        guard let path = ProcessInfo.processInfo.environment["SMALLCAST_EMO_MODEL_DIR"] else {
            print("emo-test: SMALLCAST_EMO_MODEL_DIR unset, skipping the Core ML check")
            return
        }
        let directory = URL(fileURLWithPath: path)
        let suggester = try await Task.detached { try EmoSuggester(directory: directory) }.value
        for (phrase, glyph) in [
            ("Dentist appointment", "🦷"), ("réserver un vol pour Tokyo", "✈️"),
            ("犬の散歩", "🐕"), ("จองโรงแรม", "🏨"), ("Pay my bills", "💰")
        ] {
            let started = Date()
            let ranked = try suggester.suggest(phrase, limit: 8, minimumConfidence: 0)
            let elapsed = Date().timeIntervalSince(started) * 1000
            let listing = ranked.map { "\($0.glyph) \(String(format: "%.2f", $0.confidence))" }
            print("  \(phrase): \(listing.joined(separator: " ")) (\(String(format: "%.1f", elapsed)) ms)")
            expect(ranked.prefix(2).contains { $0.glyph == glyph }, "\(phrase) suggests \(glyph) in its top two")
        }
        expect(try suggester.suggest("", limit: 8, minimumConfidence: 0).count == 8, "empty input still ranks")
    }
}
