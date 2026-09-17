// The voice engine catalog, its tokenizers and the transducer loop; the real-file legs skip
// with a reason on a Mac that has not downloaded the models.

import Foundation

@main
@MainActor
struct VoiceTests {
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

    static let models = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.smallcast.app.dev/voice-models")

    static func main() throws {
        catalogSpellings()
        catalogAssets()
        languages()
        try sentencePieceJSON()
        try sentencePieceProtobuf()
        try whisperTokenizer()
        try transducerLoop()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func catalogSpellings() {
        expect(
            VoiceEngine.allCases.map(\.rawValue) == [
                "nemotron-3.5-streaming", "nemotron-3.5-multilingual", "parakeet-flash",
                "parakeet-tdt-v3", "parakeet-tdt-v2", "cohere-transcribe", "apple-speech",
                "whisper-tiny", "whisper-base", "whisper-small", "whisper-medium", "whisper-large",
            ], "raw values are the persisted spelling, so a rename is a migration")
        expect(VoiceEngine.default == .appleSpeech, "the default needs no download")
        for engine in VoiceEngine.allCases {
            expect(!engine.strengths.isEmpty, "\(engine) names its strengths")
            expect(!engine.weaknesses.isEmpty, "\(engine) names its weaknesses")
            expect(!engine.tagline.isEmpty, "\(engine) has a tagline")
            expect(
                (engine.downloadBytes == nil) == (engine.assets == nil),
                "\(engine) states a size exactly when it downloads something")
        }
        expect(
            VoiceEngine.allCases.filter(\.requiresLanguage) == [.cohereTranscribe],
            "only Cohere refuses to guess the language")
    }

    static func catalogAssets() {
        for engine in VoiceEngine.allCases {
            guard let assets = engine.assets else { continue }
            expect(!assets.files.isEmpty, "\(engine) lists its files")
            for file in assets.files {
                expect(
                    file.url.absoluteString.hasPrefix("https://huggingface.co/\(file.repo)/resolve/main/"),
                    "\(engine) fetches \(file.path) from its own repo")
                expect(
                    file.treeURL.absoluteString.contains("/api/models/\(file.repo)/tree/main/"),
                    "\(engine) lists \(file.path) through the tree API")
            }
        }
        let bundle = VoiceModelAssets.File(repo: "a/b", path: "Encoder.mlmodelc")
        let package = VoiceModelAssets.File(repo: "a/b", path: "x/encoder.mlpackage")
        let folder = VoiceModelAssets.File(repo: "a/b", path: "openai_whisper-tiny")
        let json = VoiceModelAssets.File(repo: "a/b", path: "vocab.json")
        expect(bundle.isBundle && package.isBundle && folder.isBundle, "model bundles are folders")
        expect(!json.isBundle, "a vocabulary is one file")
        expect(
            VoiceEngine.whisperLarge.assets?.extra.first?.repo == "openai/whisper-large-v3",
            "the large tokenizer comes from the v3 checkpoint")
    }

    static func languages() {
        expect(VoiceLanguage.all.first == .auto, "automatic leads the picker")
        expect(VoiceLanguage.named("fr").name == "French", "a code resolves to its name")
        expect(VoiceLanguage.named("xx") == .auto, "an unknown code falls back to automatic")
        expect(VoiceLanguage.base(of: "fr_FR") == "fr", "an underscore locale reduces to its language")
        expect(VoiceLanguage.base(of: "pt-BR") == "pt", "a dashed locale reduces to its language")
        expect(
            Set(VoiceLanguage.all.map(\.code)).count == VoiceLanguage.all.count,
            "no language is listed twice")
    }

    static func sentencePieceJSON() throws {
        let dictionary = try SentencePieceVocabulary(
            json: Data(#"{"0":"<unk>","1":"▁hello","2":"▁wor","3":"ld","4":"<0xC3>","5":"<0xA9>","6":"."}"#.utf8))
        expect(dictionary.text(for: [1, 2, 3, 6]) == "hello world.", "pieces join into words")
        expect(dictionary.text(for: [1, 4, 5]) == "helloé", "byte fallbacks reassemble into UTF-8")
        expect(dictionary.text(for: [0, 1]) == "hello", "a tag piece is dropped")
        let array = try SentencePieceVocabulary(json: Data(#"["<unk>","▁a","b"]"#.utf8))
        expect(array.text(for: [1, 2]) == "ab", "an array vocabulary indexes by position")
        expect(array.id(ofPiece: "b") == 2, "a piece resolves back to its id")
    }

    static func sentencePieceProtobuf() throws {
        // A hand-built ModelProto: pieces field 1, each with piece (1) and score (2, fixed32).
        func piece(_ text: String) -> [UInt8] {
            let bytes = Array(text.utf8)
            let inner: [UInt8] = [0x0A, UInt8(bytes.count)] + bytes + [0x15, 0, 0, 0, 0]
            return [0x0A, UInt8(inner.count)] + inner
        }
        let proto = Data(piece("<unk>") + piece("▁hi") + piece("<en-US>") + [0x10, 0x01])
        let vocabulary = try SentencePieceVocabulary(sentencePieceModel: proto)
        expect(vocabulary.count == 3, "three pieces are read")
        expect(vocabulary.piece(1) == "▁hi", "pieces keep their order as ids")
        expect(vocabulary.id(ofPiece: "<en-US>") == 2, "a language tag resolves to its id")
        expect(vocabulary.text(for: [2, 1]) == "hi", "a language tag is dropped from the text")

        let real = models.appendingPathComponent(
            "BarathwajAnandan/nemotron-3.5-asr-offline-6bit-CoreML/tokenizer.model")
        guard let data = try? Data(contentsOf: real) else {
            print("skip: Nemotron tokenizer.model not downloaded")
            return
        }
        let nemotron = try SentencePieceVocabulary(sentencePieceModel: data)
        expect(nemotron.count == 13_087, "the Nemotron vocabulary has 13087 pieces, got \(nemotron.count)")
        expect(nemotron.piece(150) == "▁the", "piece 150 is ▁the")
        expect(nemotron.id(ofPiece: "<en-US>") == 2947, "the English tag is piece 2947")
    }

    static func whisperTokenizer() throws {
        let real = models.appendingPathComponent("openai/whisper-tiny/tokenizer.json")
        guard let data = try? Data(contentsOf: real) else {
            print("skip: Whisper tokenizer.json not downloaded")
            return
        }
        let vocabulary = try WhisperVocabulary(tokenizerJSON: data)
        expect(vocabulary.endOfText == 50257, "end of text is 50257")
        expect(vocabulary.startOfTranscript == 50258, "start of transcript is 50258")
        expect(vocabulary.languageToken("en") == 50259, "English is 50259")
        expect(vocabulary.transcribe == 50359, "transcribe is 50359")
        expect(vocabulary.noTimestamps == 50363, "no timestamps is 50363")
        expect(vocabulary.firstTimestamp == 50364, "the first timestamp is 50364")
        expect(vocabulary.languageTokens.count == 99, "99 languages, got \(vocabulary.languageTokens.count)")
        // A word after a space is one token spelled with Ġ; é is two bytes in two tokens or one.
        let hello = vocabulary.id(ofToken: "ĠHello")!
        let decoded = vocabulary.text(for: [hello, hello, 50257, 50364])
        expect(decoded == "Hello Hello", "byte-level tokens decode to text, got \(decoded)")
        let accent = vocabulary.id(ofToken: "Ã©")!
        expect(vocabulary.text(for: [accent]) == "é", "a two-byte character reassembles")
        expect(vocabulary.text(for: [50258, 50259]) == "", "specials produce no text")
    }

    /// A scripted network: frame → (token, bin), with the LSTM state counting predictions.
    struct ScriptedNetwork: TransducerNetwork {
        var script: [Int: [(Int, Int)]]
        var predictions: [Int] = []

        mutating func predict(token: Int, state: Int) throws -> (projection: [Float], state: Int) {
            predictions.append(token)
            return ([Float(token)], state + 1)
        }

        mutating func join(frame: Int, projection: [Float]) throws -> (token: Int, durationBin: Int) {
            guard var steps = script[frame], !steps.isEmpty else { return (99, 1) }
            let step = steps.removeFirst()
            script[frame] = steps
            return step
        }
    }

    static func transducerLoop() throws {
        let blank = 99
        let decoder = TransducerDecoder(blankID: blank, durationBins: [0, 1, 2, 3, 4])
        var network = ScriptedNetwork(script: [
            0: [(5, 0)],  // a token, stay on the frame
            1: [(blank, 2)],
            3: [(7, 1)],
        ])
        // Frame 0 is asked twice: once for the token, once for what follows it.
        network.script[0] = [(5, 0), (blank, 1)]
        var carry = TransducerDecoder.Carry(state: 0, lastToken: nil, projection: nil)
        let tokens = try decoder.decode(frameCount: 5, network: &network, carry: &carry)
        expect(tokens == [5, 7], "tokens are emitted in order, blanks skipped, got \(tokens)")
        expect(network.predictions.first == blank, "the prediction network is primed with blank")
        expect(network.predictions == [blank, 5, 7], "the LSTM steps once per emitted token")
        expect(carry.lastToken == 7, "the carry remembers the last token for the next chunk")
        expect(carry.state == 3, "the carry holds the moved-on state")

        var stuck = ScriptedNetwork(script: [:])
        for frame in 0..<3 { stuck.script[frame] = Array(repeating: (1, 0), count: 40) }
        var stuckCarry = TransducerDecoder.Carry(state: 0, lastToken: nil, projection: nil)
        let looped = try decoder.decode(frameCount: 3, network: &stuck, carry: &stuckCarry)
        expect(
            looped.count == 3 * TransducerDecoder.maxSymbolsPerFrame,
            "a model stuck on a frame is forced forward after the symbol cap, got \(looped.count)")

        let rnnt = TransducerDecoder(blankID: blank, durationBins: [0])
        var plain = ScriptedNetwork(script: [0: [(3, 0), (4, 0), (blank, 0)], 1: [(5, 0), (blank, 0)]])
        var plainCarry = TransducerDecoder.Carry(state: 0, lastToken: nil, projection: nil)
        let rnntTokens = try rnnt.decode(frameCount: 2, network: &plain, carry: &plainCarry)
        expect(
            rnntTokens == [3, 4, 5],
            "a plain RNNT stays on a frame until it hears a blank, got \(rnntTokens)")
    }
}
