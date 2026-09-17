import Foundation

/// Every speech-to-text engine the AI's voice mode can run. See docs/features/voice.md.
enum VoiceEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case nemotronStreaming = "nemotron-3.5-streaming"
    case nemotronMultilingual = "nemotron-3.5-multilingual"
    case parakeetFlash = "parakeet-flash"
    case parakeetV3 = "parakeet-tdt-v3"
    case parakeetV2 = "parakeet-tdt-v2"
    case cohereTranscribe = "cohere-transcribe"
    case appleSpeech = "apple-speech"
    case whisperTiny = "whisper-tiny"
    case whisperBase = "whisper-base"
    case whisperSmall = "whisper-small"
    case whisperMedium = "whisper-medium"
    case whisperLarge = "whisper-large"

    var id: String { rawValue }

    /// The one that needs no download: every Mac running Smallcast has it.
    static let `default` = VoiceEngine.appleSpeech

    enum Vendor: String, Sendable {
        case nvidia = "NVIDIA"
        case cohere = "Cohere"
        case apple = "Apple"
        case openAI = "OpenAI"
    }

    /// How the engine runs; each case is one transcriber in `Service/`.
    enum Runtime: Sendable, Equatable {
        case appleSpeech
        /// A NeMo transducer whose encoder takes the whole utterance at once.
        case transducer(TransducerLayout)
        /// A NeMo transducer whose encoder is fed in chunks and carries a cache between them.
        case streamingTransducer(StreamingTransducerLayout)
        case cohere
        case whisper
    }

    var vendor: Vendor {
        switch self {
        case .nemotronStreaming, .nemotronMultilingual, .parakeetFlash, .parakeetV3, .parakeetV2:
            return .nvidia
        case .cohereTranscribe: return .cohere
        case .appleSpeech: return .apple
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return .openAI
        }
    }

    var title: String {
        switch self {
        case .nemotronStreaming: return "Speech 3.5 — Ultra Fast Low Latency"
        case .nemotronMultilingual: return "Speech 3.5 — Multilingual"
        case .parakeetFlash: return "Parakeet Flash (Beta)"
        case .parakeetV3: return "Parakeet TDT v3"
        case .parakeetV2: return "Parakeet TDT v2"
        case .cohereTranscribe: return "Cohere Transcribe"
        case .appleSpeech: return "Apple Speech"
        case .whisperTiny: return "Whisper Tiny"
        case .whisperBase: return "Whisper Base"
        case .whisperSmall: return "Whisper Small"
        case .whisperMedium: return "Whisper Medium"
        case .whisperLarge: return "Whisper Large"
        }
    }

    /// One line under the title.
    var tagline: String {
        switch self {
        case .nemotronStreaming: return "NVIDIA Nemotron 3.5, tuned for speed in about 40 languages."
        case .nemotronMultilingual: return "NVIDIA Nemotron 3.5, tuned for accuracy in about 40 languages."
        case .parakeetFlash: return "A small English model built for live dictation."
        case .parakeetV3: return "Fast transcription in 25 European languages."
        case .parakeetV2: return "The fastest and most accurate Parakeet for English."
        case .cohereTranscribe: return "The most accurate engine here, in 14 languages."
        case .appleSpeech: return "The speech recognizer built into macOS. Nothing to download."
        case .whisperTiny: return "The smallest Whisper. Quick, and rough on detail."
        case .whisperBase: return "A small Whisper with a fair balance of speed and accuracy."
        case .whisperSmall: return "A mid-size Whisper that gets most words right."
        case .whisperMedium: return "A large Whisper for careful transcription."
        case .whisperLarge: return "Whisper large-v3, the most accurate Whisper."
        }
    }

    var strengths: [String] {
        switch self {
        case .nemotronStreaming:
            return [
                "Very low latency: the transcript is ready almost as you release the key.",
                "Detects the language on its own, or takes the one you pick.",
                "About 40 languages, including Chinese, Japanese, Korean and Hindi.",
            ]
        case .nemotronMultilingual:
            return [
                "More accurate than the low-latency Speech 3.5 on the same audio.",
                "Detects the language on its own, or takes the one you pick.",
                "About 40 languages, including Chinese, Japanese, Korean and Hindi.",
            ]
        case .parakeetFlash:
            return [
                "The smallest download of the NVIDIA models.",
                "Built for live dictation, so short questions come back fast.",
                "Light on memory.",
            ]
        case .parakeetV3:
            return [
                "Fast on Apple Silicon: several times faster than real time.",
                "25 European languages, switched automatically.",
                "Good punctuation and capitalisation.",
            ]
        case .parakeetV2:
            return [
                "The best English accuracy of the Parakeet family.",
                "As fast as Parakeet v3.",
                "Good punctuation and capitalisation.",
            ]
        case .cohereTranscribe:
            return [
                "The highest accuracy in this list.",
                "Strong on Arabic, Japanese, Chinese, Korean and Vietnamese.",
                "Handles names and rare words better than the smaller models.",
            ]
        case .appleSpeech:
            return [
                "No download and no setup: it works the moment you turn voice on.",
                "Runs on device, like every engine here.",
                "Follows the languages installed in System Settings.",
            ]
        case .whisperTiny:
            return ["Tiny download.", "Fastest Whisper.", "Understands 99 languages."]
        case .whisperBase:
            return [
                "Small download.", "Noticeably more accurate than Tiny.",
                "Understands 99 languages.",
            ]
        case .whisperSmall:
            return [
                "Good accuracy for everyday speech.", "Understands 99 languages.",
                "Moderate download.",
            ]
        case .whisperMedium:
            return ["High accuracy.", "Understands 99 languages.", "Robust to accents and noise."]
        case .whisperLarge:
            return [
                "The most accurate Whisper.", "Understands 99 languages.",
                "The best Whisper for accents, noise and rare words.",
            ]
        }
    }

    var weaknesses: [String] {
        switch self {
        case .nemotronStreaming:
            return [
                "Beta: an occasional dropped or garbled word.",
                "Some languages are alpha or experimental quality.",
                "Wants 8 GB of memory.",
            ]
        case .nemotronMultilingual:
            return [
                "Slower than the low-latency Speech 3.5.",
                "Some languages are alpha or experimental quality.",
                "Wants 8 GB of memory.",
            ]
        case .parakeetFlash:
            return [
                "English only.",
                "The least accurate of the NVIDIA models.",
                "Beta: it can stop early on a long question.",
            ]
        case .parakeetV3:
            return [
                "No Chinese, Japanese, Korean or Arabic.",
                "Less accurate than Parakeet v2 on English.",
            ]
        case .parakeetV2:
            return ["English only."]
        case .cohereTranscribe:
            return [
                "The biggest download here.",
                "You have to pick the language; it does not detect it.",
                "Slow: about 20 seconds per question on an M-series Mac, however short the question.",
                "Wants 8 GB of memory.",
            ]
        case .appleSpeech:
            return [
                "Weaker on names, jargon and mixed-language speech.",
                "A language you have not used before downloads its assets first.",
            ]
        case .whisperTiny:
            return ["The least accurate engine here.", "Can invent words in silence or noise."]
        case .whisperBase:
            return ["Still misses words in noise or with accents.", "Can invent words in silence."]
        case .whisperSmall:
            return ["Slower than the Parakeets.", "Can invent words in silence."]
        case .whisperMedium:
            return ["Large download.", "Slow: expect a pause after you release the key."]
        case .whisperLarge:
            return [
                "Large download.", "The slowest Whisper.", "Wants 8 GB of memory or more.",
            ]
        }
    }

    /// A short statement of language coverage for the settings card.
    var languages: String {
        switch self {
        case .nemotronStreaming, .nemotronMultilingual: return "About 40 languages"
        case .parakeetFlash, .parakeetV2: return "English"
        case .parakeetV3: return "25 European languages"
        case .cohereTranscribe: return "14 languages"
        case .appleSpeech: return "System languages"
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return "99 languages"
        }
    }

    /// The engine only works once a language is picked; `auto` is not an option for it.
    var requiresLanguage: Bool { self == .cohereTranscribe }

    /// Whether picking a language changes what the engine does at all.
    var takesLanguage: Bool {
        switch self {
        case .parakeetFlash, .parakeetV3, .parakeetV2: return false
        default: return true
        }
    }

    /// Bytes fetched on first use; nil for the engine that ships with macOS.
    var downloadBytes: Int64? {
        switch self {
        case .nemotronStreaming: return 700_264_697
        case .nemotronMultilingual: return 556_139_297
        case .parakeetFlash: return 225_231_771
        case .parakeetV3: return 632_018_607
        case .parakeetV2: return 464_394_485
        case .cohereTranscribe: return 2_189_088_364
        case .appleSpeech: return nil
        case .whisperTiny: return 76_635_397
        case .whisperBase: return 146_719_453
        case .whisperSmall: return 486_487_465
        case .whisperMedium: return 1_529_654_233
        case .whisperLarge: return 948_108_786
        }
    }

    var runtime: Runtime {
        switch self {
        case .nemotronStreaming: return .streamingTransducer(.nemotron)
        case .nemotronMultilingual: return .transducer(.nemotron)
        case .parakeetFlash: return .streamingTransducer(.parakeetEOU)
        case .parakeetV3: return .transducer(.parakeetV3)
        case .parakeetV2: return .transducer(.parakeetV2)
        case .cohereTranscribe: return .cohere
        case .appleSpeech: return .appleSpeech
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return .whisper
        }
    }

    /// What to fetch from Hugging Face; nil for the engine that ships with macOS.
    var assets: VoiceModelAssets? {
        switch self {
        case .nemotronStreaming:
            return VoiceModelAssets(
                repo: "BarathwajAnandan/nemotron-3.5-asr-streaming320-int8-CoreML",
                paths: [
                    "preprocessor.mlpackage", "encoder.mlpackage", "decoder.mlpackage",
                    "joint_decision.mlpackage", "metadata.json", "tokenizer.model",
                ])
        case .nemotronMultilingual:
            return VoiceModelAssets(
                repo: "BarathwajAnandan/nemotron-3.5-asr-offline-6bit-CoreML",
                paths: [
                    "preprocessor.mlpackage", "encoder.mlpackage", "decoder.mlpackage",
                    "joint_decision.mlpackage", "metadata.json", "tokenizer.model",
                ])
        case .parakeetFlash:
            return VoiceModelAssets(
                repo: "FluidInference/parakeet-realtime-eou-120m-coreml",
                paths: [
                    "160ms/parakeet_eou_preprocessor.mlmodelc", "160ms/streaming_encoder.mlmodelc",
                    "160ms/decoder.mlmodelc", "160ms/joint_decision.mlmodelc", "160ms/vocab.json",
                ])
        case .parakeetV3:
            return VoiceModelAssets(
                repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                paths: [
                    "Preprocessor.mlmodelc", "Encoder_v2.mlmodelc", "Decoder.mlmodelc",
                    "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
                ])
        case .parakeetV2:
            return VoiceModelAssets(
                repo: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
                paths: [
                    "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
                    "JointDecision.mlmodelc", "parakeet_vocab.json",
                ])
        case .cohereTranscribe:
            return VoiceModelAssets(
                repo: "FluidInference/cohere-transcribe-03-2026-coreml",
                paths: [
                    "q8/cohere_encoder.mlmodelc", "q8/cohere_decoder_cache_external_v2.mlmodelc",
                    "vocab.json",
                ])
        case .appleSpeech:
            return nil
        case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLarge:
            return VoiceModelAssets(
                repo: "argmaxinc/whisperkit-coreml",
                paths: [whisperFolder!],
                extra: [VoiceModelAssets.File(repo: whisperTokenizerRepo!, path: "tokenizer.json")])
        }
    }

    /// The WhisperKit folder; nil for every other engine.
    var whisperFolder: String? {
        switch self {
        case .whisperTiny: return "openai_whisper-tiny"
        case .whisperBase: return "openai_whisper-base"
        case .whisperSmall: return "openai_whisper-small"
        case .whisperMedium: return "openai_whisper-medium"
        case .whisperLarge: return "openai_whisper-large-v3_947MB"
        default: return nil
        }
    }

    /// The tokenizer travels with OpenAI's own checkpoint, not with the CoreML export.
    var whisperTokenizerRepo: String? {
        switch self {
        case .whisperTiny: return "openai/whisper-tiny"
        case .whisperBase: return "openai/whisper-base"
        case .whisperSmall: return "openai/whisper-small"
        case .whisperMedium: return "openai/whisper-medium"
        case .whisperLarge: return "openai/whisper-large-v3"
        default: return nil
        }
    }
}

/// The files one engine needs from Hugging Face. A path ending in a model bundle is a folder.
struct VoiceModelAssets: Sendable, Equatable {
    struct File: Sendable, Equatable, Hashable {
        let repo: String
        let path: String

        var url: URL {
            URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!
        }

        /// A folder's contents are listed on demand, since a bundle holds several files.
        var treeURL: URL {
            URL(string: "https://huggingface.co/api/models/\(repo)/tree/main/\(path)?recursive=true")!
        }

        var isBundle: Bool {
            path.hasSuffix(".mlmodelc") || path.hasSuffix(".mlpackage") || !path.contains(".")
        }
    }

    let repo: String
    let paths: [String]
    var extra: [File] = []

    var files: [File] { paths.map { File(repo: repo, path: $0) } + extra }
}

/// Feature names and constants for a NeMo transducer whose encoder sees the whole utterance.
struct TransducerLayout: Sendable, Equatable {
    enum Family: Sendable { case parakeet, nemotron }

    let family: Family
    let preprocessor: String
    let encoder: String
    let decoder: String
    let joint: String
    let vocabulary: String
    /// The blank id is also the start-of-sequence token that primes the prediction network.
    let blankID: Int
    /// Frames to advance per emitted token, by bin; a plain RNNT stays put until it hears a blank.
    let durationBins: [Int]
    let decoderLayers: Int
    /// The window the encoder was exported for, in samples at 16 kHz.
    let maxSamples: Int

    static let parakeetV3 = TransducerLayout(
        family: .parakeet, preprocessor: "Preprocessor.mlmodelc", encoder: "Encoder_v2.mlmodelc",
        decoder: "Decoder.mlmodelc", joint: "JointDecisionv3.mlmodelc",
        vocabulary: "parakeet_vocab.json", blankID: 8192, durationBins: [0, 1, 2, 3, 4],
        decoderLayers: 2, maxSamples: 240_000)

    static let parakeetV2 = TransducerLayout(
        family: .parakeet, preprocessor: "Preprocessor.mlmodelc", encoder: "Encoder.mlmodelc",
        decoder: "Decoder.mlmodelc", joint: "JointDecision.mlmodelc",
        vocabulary: "parakeet_vocab.json", blankID: 1024, durationBins: [0, 1, 2, 3, 4],
        decoderLayers: 2, maxSamples: 240_000)

    static let nemotron = TransducerLayout(
        family: .nemotron, preprocessor: "preprocessor.mlpackage", encoder: "encoder.mlpackage",
        decoder: "decoder.mlpackage", joint: "joint_decision.mlpackage",
        vocabulary: "tokenizer.model", blankID: 13_087, durationBins: [0], decoderLayers: 2,
        maxSamples: 240_000)
}

/// Feature names and constants for a cache-aware streaming NeMo encoder.
struct StreamingTransducerLayout: Sendable, Equatable {
    enum Family: Sendable { case parakeetEOU, nemotron }

    let family: Family
    let folder: String
    let preprocessor: String
    let encoder: String
    let decoder: String
    let joint: String
    let vocabulary: String
    let blankID: Int
    let decoderLayers: Int

    static let parakeetEOU = StreamingTransducerLayout(
        family: .parakeetEOU, folder: "160ms", preprocessor: "parakeet_eou_preprocessor.mlmodelc",
        encoder: "streaming_encoder.mlmodelc", decoder: "decoder.mlmodelc",
        joint: "joint_decision.mlmodelc", vocabulary: "vocab.json", blankID: 1026, decoderLayers: 1)

    static let nemotron = StreamingTransducerLayout(
        family: .nemotron, folder: "", preprocessor: "preprocessor.mlpackage",
        encoder: "encoder.mlpackage", decoder: "decoder.mlpackage",
        joint: "joint_decision.mlpackage", vocabulary: "tokenizer.model", blankID: 13_087,
        decoderLayers: 2)
}
