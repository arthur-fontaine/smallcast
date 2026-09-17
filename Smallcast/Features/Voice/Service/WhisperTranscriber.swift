import CoreML
import Foundation

/// OpenAI Whisper from WhisperKit's CoreML export: mel → encoder → autoregressive text decoder.
final class WhisperTranscriber: VoiceTranscriber, @unchecked Sendable {
    /// Whisper always sees 30 s; shorter audio is zero-padded, longer audio is cut into windows.
    private static let windowSamples = 480_000
    /// Tokens a window may produce, bounded by the decoder's key/value cache.
    private let contextLength: Int
    private let mel: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let vocabulary: WhisperVocabulary
    private let kvWidth: Int
    private let cacheType: MLMultiArrayDataType
    private let maskType: MLMultiArrayDataType

    nonisolated init(directory: URL, tokenizer: URL) async throws {
        mel = try await CoreMLSupport.load("MelSpectrogram.mlmodelc", in: directory, units: .cpuAndGPU)
        encoder = try await CoreMLSupport.load(
            "AudioEncoder.mlmodelc", in: directory, units: .cpuAndNeuralEngine)
        // The decoder's external cache reads back wrong on the Neural Engine; the GPU is exact.
        decoder = try await CoreMLSupport.load("TextDecoder.mlmodelc", in: directory, units: .cpuAndGPU)
        guard let data = try? Data(contentsOf: tokenizer) else {
            throw VoiceTranscriptionError.modelMissing("Whisper tokenizer")
        }
        vocabulary = try WhisperVocabulary(tokenizerJSON: data)
        let cacheShape = CoreMLSupport.inputShape(decoder, "key_cache")
        guard cacheShape.count == 4 else {
            throw VoiceTranscriptionError.malformedModel("key_cache is not 4-D")
        }
        kvWidth = cacheShape[1]
        contextLength = cacheShape[3]
        cacheType = CoreMLSupport.inputType(decoder, "key_cache")
        maskType = CoreMLSupport.inputType(decoder, "decoder_key_padding_mask")
    }

    func transcribe(_ audio: VoiceAudio, language: VoiceLanguage) async throws -> String {
        var pieces: [String] = []
        var start = 0
        repeat {
            let end = min(start + Self.windowSamples, audio.samples.count)
            let window = Array(audio.samples[start..<end])
            start = end
            let embeds = try encode(window)
            var code = language.isAuto ? nil : language.code
            if code == nil { code = try detectLanguage(embeds) }
            guard let code, let languageToken = vocabulary.languageToken(code) else {
                throw VoiceTranscriptionError.unsupportedLanguage(code ?? "auto")
            }
            let prompt = [
                vocabulary.startOfTranscript, languageToken, vocabulary.transcribe,
                vocabulary.noTimestamps,
            ]
            let tokens = try decode(embeds, prompt: prompt, restrictTo: nil)
            pieces.append(vocabulary.text(for: tokens))
            try Task.checkCancellation()
        } while start < audio.samples.count
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func encode(_ samples: [Float]) throws -> MLMultiArray {
        let audio = try CoreMLSupport.array(
            [Self.windowSamples], CoreMLSupport.inputType(mel, "audio"))
        CoreMLSupport.fill(audio, with: samples)
        let features = try CoreMLSupport.output(
            try mel.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "audio": MLFeatureValue(multiArray: audio)
                ])), "melspectrogram_features")
        let embeds = try CoreMLSupport.output(
            try encoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "melspectrogram_features": MLFeatureValue(multiArray: features)
                ])), "encoder_output_embeds")
        return embeds
    }

    /// One decoder step on start-of-transcript, with the answer restricted to language tokens.
    private func detectLanguage(_ embeds: MLMultiArray) throws -> String {
        let languages = vocabulary.languageTokens
        let picked = try decode(
            embeds, prompt: [vocabulary.startOfTranscript], restrictTo: Set(languages.keys),
            maxNewTokens: 1)
        guard let token = picked.first, let code = languages[token] else { return "en" }
        return code
    }

    /// Greedy decoding with an external key/value cache, one token per prediction.
    private func decode(
        _ embeds: MLMultiArray, prompt: [Int], restrictTo allowed: Set<Int>?, maxNewTokens: Int? = nil
    ) throws -> [Int] {
        let keyCache = try CoreMLSupport.array([1, kvWidth, 1, contextLength], cacheType)
        let valueCache = try CoreMLSupport.array([1, kvWidth, 1, contextLength], cacheType)
        let updateMask = try CoreMLSupport.array(
            [1, contextLength], CoreMLSupport.inputType(decoder, "kv_cache_update_mask"))
        let paddingMask = try CoreMLSupport.array([1, contextLength], maskType)
        CoreMLSupport.fill(paddingMask, with: [Float](repeating: -10_000, count: contextLength))
        let inputIDs = try CoreMLSupport.array([1], .int32)
        let cacheLength = try CoreMLSupport.array([1], .int32)

        var tokens = prompt
        var produced: [Int] = []
        let limit = min(contextLength - 1, prompt.count + (maxNewTokens ?? contextLength))
        for index in 0..<limit {
            let current = index < tokens.count ? tokens[index] : produced.last!
            inputIDs[0] = NSNumber(value: current)
            cacheLength[0] = NSNumber(value: index)
            var update = [Float](repeating: 0, count: contextLength)
            update[index] = 1
            CoreMLSupport.fill(updateMask, with: update)
            paddingMask[index] = 0
            let output = try decoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": MLFeatureValue(multiArray: inputIDs),
                    "cache_length": MLFeatureValue(multiArray: cacheLength),
                    "key_cache": MLFeatureValue(multiArray: keyCache),
                    "value_cache": MLFeatureValue(multiArray: valueCache),
                    "kv_cache_update_mask": MLFeatureValue(multiArray: updateMask),
                    "encoder_output_embeds": MLFeatureValue(multiArray: embeds),
                    "decoder_key_padding_mask": MLFeatureValue(multiArray: paddingMask),
                ]))
            Self.store(try CoreMLSupport.output(output, "key_cache_updates"), into: keyCache, at: index)
            Self.store(
                try CoreMLSupport.output(output, "value_cache_updates"), into: valueCache, at: index)
            // While the prompt is still being fed, the prediction is discarded.
            guard index >= prompt.count - 1 else { continue }
            var logits = CoreMLSupport.floats(try CoreMLSupport.output(output, "logits"))
            let next = pick(&logits, allowed: allowed, first: produced.isEmpty)
            if next == vocabulary.endOfText { break }
            produced.append(next)
            tokens.append(next)
            if let maxNewTokens, produced.count >= maxNewTokens { break }
        }
        return produced
    }

    /// Argmax over what the step may say: plain text plus end-of-text, or a given set.
    private func pick(_ logits: inout [Float], allowed: Set<Int>?, first: Bool) -> Int {
        if let allowed {
            for index in logits.indices where !allowed.contains(index) { logits[index] = -.infinity }
            return CoreMLSupport.argmax(logits)
        }
        for index in vocabulary.firstSpecial..<logits.count where index != vocabulary.endOfText {
            logits[index] = -.infinity
        }
        // A window that opens on a lone space is Whisper's way of saying it heard nothing yet.
        if first, let space = vocabulary.id(ofToken: "Ġ") { logits[space] = -.infinity }
        return CoreMLSupport.argmax(logits)
    }

    /// The decoder returns one column of cache per step; it goes into slot `index`.
    private static func store(_ update: MLMultiArray, into cache: MLMultiArray, at index: Int) {
        let width = cache.shape[1].intValue
        let strides = cache.strides.map(\.intValue)
        let source = CoreMLSupport.floats(update)
        switch cache.dataType {
        case .float16:
            cache.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
                for row in 0..<width where row < source.count {
                    buffer[row * strides[1] + index * strides[3]] = Float16(source[row])
                }
            }
        default:
            cache.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for row in 0..<width where row < source.count {
                    buffer[row * strides[1] + index * strides[3]] = source[row]
                }
            }
        }
    }
}
