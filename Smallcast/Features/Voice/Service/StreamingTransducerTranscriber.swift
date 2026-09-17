import CoreML
import Foundation

/// Parakeet Flash and the streaming Nemotron: a cache-aware encoder fed hop by hop, then RNNT.
final class StreamingTransducerTranscriber: VoiceTranscriber, @unchecked Sendable {
    private let layout: StreamingTransducerLayout
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: SentencePieceVocabulary
    private let prompts: [String: Int]
    private let promptCount: Int
    /// Mel frames the encoder sees per call, and how many of them are new audio each hop.
    private let windowFrames: Int
    private let hopFrames: Int

    nonisolated init(layout: StreamingTransducerLayout, directory: URL) async throws {
        self.layout = layout
        let folder = layout.folder.isEmpty ? directory : directory.appendingPathComponent(layout.folder)
        preprocessor = try await CoreMLSupport.load(layout.preprocessor, in: folder, units: .cpuOnly)
        encoder = try await CoreMLSupport.load(layout.encoder, in: folder, units: .cpuAndNeuralEngine)
        decoder = try await CoreMLSupport.load(layout.decoder, in: folder, units: .cpuOnly)
        joint = try await CoreMLSupport.load(layout.joint, in: folder, units: .cpuOnly)
        let vocabularyData = try Data(contentsOf: folder.appendingPathComponent(layout.vocabulary))
        switch layout.family {
        case .parakeetEOU:
            vocabulary = try SentencePieceVocabulary(json: vocabularyData)
            prompts = [:]
            promptCount = 0
            windowFrames = CoreMLSupport.inputShape(encoder, "audio_signal").last ?? 17
            // Half a window per step: the export was trained on 50 % overlap and hears nothing else.
            hopFrames = (windowFrames - 1) / 2
        case .nemotron:
            vocabulary = try SentencePieceVocabulary(sentencePieceModel: vocabularyData)
            let metadata = try NemotronMetadata(contentsOf: folder.appendingPathComponent("metadata.json"))
            prompts = metadata.prompts
            promptCount = metadata.promptCount
            windowFrames = CoreMLSupport.inputShape(encoder, "processed_signal").last ?? 73
            hopFrames = metadata.streamingShiftFrames
        }
    }

    func transcribe(_ audio: VoiceAudio, language: VoiceLanguage) async throws -> String {
        switch layout.family {
        case .parakeetEOU: return try transcribeEOU(audio)
        case .nemotron: return try transcribeNemotron(audio, language: language)
        }
    }

    // MARK: - Parakeet Flash

    /// Each hop is its own mel: the exported preprocessor normalizes per chunk, as NeMo does live.
    private func transcribeEOU(_ audio: VoiceAudio) throws -> String {
        let hopSamples = hopFrames * 160
        var preCache = try CoreMLSupport.array(CoreMLSupport.inputShape(encoder, "pre_cache"), .float32)
        var channelCache = try CoreMLSupport.array(
            CoreMLSupport.inputShape(encoder, "cache_last_channel"), .float32)
        var timeCache = try CoreMLSupport.array(CoreMLSupport.inputShape(encoder, "cache_last_time"), .float32)
        var channelLength = try CoreMLSupport.scalar(0)
        var network = RNNTNetwork(decoder: decoder, joint: joint, layout: layout)
        var state = try TransducerState(layers: layout.decoderLayers)
        var lastToken = layout.blankID
        var tokens: [Int] = []
        // One silent hop at the end lets the model close the last word.
        let padded = audio.samples + [Float](repeating: 0, count: hopSamples)
        var start = 0
        while start < padded.count {
            let windowSamples = (windowFrames - 1) * 160
            var chunk = Array(padded[start..<min(start + windowSamples, padded.count)])
            if chunk.count < windowSamples { chunk += [Float](repeating: 0, count: windowSamples - chunk.count) }
            start += hopSamples
            let mel = try melFrames(chunk, count: windowFrames)
            let output = try encoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "audio_signal": MLFeatureValue(multiArray: mel),
                    "audio_length": MLFeatureValue(multiArray: try CoreMLSupport.scalar(windowFrames)),
                    "pre_cache": MLFeatureValue(multiArray: preCache),
                    "cache_last_channel": MLFeatureValue(multiArray: channelCache),
                    "cache_last_channel_len": MLFeatureValue(multiArray: channelLength),
                    "cache_last_time": MLFeatureValue(multiArray: timeCache),
                ]))
            preCache = try CoreMLSupport.output(output, "new_pre_cache")
            channelCache = try CoreMLSupport.output(output, "new_cache_last_channel")
            timeCache = try CoreMLSupport.output(output, "new_cache_last_time")
            channelLength = try CoreMLSupport.output(output, "new_cache_last_channel_len")
            let encoded = EncodedAudio(
                array: try CoreMLSupport.output(output, "encoded_output"),
                frames: CoreMLSupport.int(try CoreMLSupport.output(output, "encoded_length")))
            tokens += try network.decode(
                encoded, state: &state, lastToken: &lastToken, blank: layout.blankID,
                skipping: Self.eouToken)
            try Task.checkCancellation()
        }
        return vocabulary.text(for: tokens)
    }

    /// Parakeet Flash's end-of-utterance token. A hold already knows where the utterance ends, so it
    /// is dropped rather than obeyed: live dictation stops on it, a recording would lose its tail.
    private static let eouToken = 1024

    /// The exported preprocessor on one hop, padded or cut to the frame count the encoder wants.
    private func melFrames(_ samples: [Float], count: Int) throws -> MLMultiArray {
        let signal = try CoreMLSupport.array([1, samples.count], .float32)
        CoreMLSupport.fill(signal, with: samples)
        let output = try preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "audio_signal": MLFeatureValue(multiArray: signal),
                "audio_length": MLFeatureValue(multiArray: try CoreMLSupport.scalar(samples.count)),
            ]))
        let mel = try CoreMLSupport.output(output, layout.family == .parakeetEOU ? "mel" : "processed_signal")
        return try mel.window(from: 0, count: count)
    }

    // MARK: - Nemotron streaming

    /// The stateful encoder walks a fixed window over one mel of the whole utterance, hop by hop.
    private func transcribeNemotron(_ audio: VoiceAudio, language: VoiceLanguage) throws -> String {
        let signal = try CoreMLSupport.array([1, audio.samples.count], .float32)
        CoreMLSupport.fill(signal, with: audio.samples)
        let melOutput = try preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "audio_signal": MLFeatureValue(multiArray: signal),
                "audio_length": MLFeatureValue(multiArray: try CoreMLSupport.scalar(audio.samples.count)),
            ]))
        let mel = try CoreMLSupport.output(melOutput, "processed_signal")
        let totalFrames = CoreMLSupport.int(try CoreMLSupport.output(melOutput, "processed_signal_length"))
        let prompt = try CoreMLSupport.array([1, promptCount], .float32)
        prompt[promptID(for: language)] = 1
        let encoderState = encoder.makeState()
        var timeCache = try CoreMLSupport.array(
            CoreMLSupport.inputShape(encoder, "cache_last_time"),
            CoreMLSupport.inputType(encoder, "cache_last_time"))
        var channelLength = try CoreMLSupport.scalar(0)
        var network = RNNTNetwork(decoder: decoder, joint: joint, layout: layout)
        var state = try TransducerState(layers: layout.decoderLayers)
        var lastToken = layout.blankID
        var tokens: [Int] = []
        // The window ends where the new hop ends; what precedes the hop is context the model expects.
        // Two hops of silence let the model close the last word: its output lags the window.
        var end = hopFrames
        while end - hopFrames < totalFrames + 2 * hopFrames {
            let window = try mel.window(from: end - windowFrames, count: windowFrames)
            let output = try encoder.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "processed_signal": MLFeatureValue(multiArray: window),
                    "processed_signal_length": MLFeatureValue(
                        multiArray: try CoreMLSupport.scalar(windowFrames)),
                    "prompt_vector": MLFeatureValue(multiArray: prompt),
                    "cache_last_time": MLFeatureValue(multiArray: timeCache),
                    "cache_last_channel_len": MLFeatureValue(multiArray: channelLength),
                ]), using: encoderState)
            timeCache = try CoreMLSupport.output(output, "cache_last_time_next")
            channelLength = try CoreMLSupport.output(output, "cache_last_channel_next_len")
            let encoded = EncodedAudio(
                array: try CoreMLSupport.output(output, "encoded"),
                frames: CoreMLSupport.int(try CoreMLSupport.output(output, "encoded_len")))
            tokens += try network.decode(
                encoded, state: &state, lastToken: &lastToken, blank: layout.blankID, skipping: nil)
            end += hopFrames
            try Task.checkCancellation()
        }
        return vocabulary.text(for: tokens)
    }

    private func promptID(for language: VoiceLanguage) -> Int {
        let auto = prompts["auto"] ?? 0
        guard !language.isAuto else { return auto }
        if let exact = prompts[language.code] { return exact }
        return prompts.first { VoiceLanguage.base(of: $0.key) == language.code }?.value ?? auto
    }
}

/// Greedy RNNT over one encoder chunk: at most two symbols a frame, state kept across chunks.
private struct RNNTNetwork {
    let decoder: MLModel
    let joint: MLModel
    let layout: StreamingTransducerLayout

    private static let maxSymbolsPerFrame = 2

    mutating func decode(
        _ encoded: EncodedAudio, state: inout TransducerState, lastToken: inout Int, blank: Int,
        skipping skipped: Int?
    ) throws -> [Int] {
        var tokens: [Int] = []
        let parakeet = layout.family == .parakeetEOU
        for frame in 0..<encoded.frames {
            let encoderStep = try CoreMLSupport.array([1, encoded.hidden, 1], .float32)
            CoreMLSupport.fill(encoderStep, with: encoded.frame(frame))
            for _ in 0..<Self.maxSymbolsPerFrame {
                let targets = try CoreMLSupport.array([1, 1], .int32)
                targets[0] = NSNumber(value: lastToken)
                let predicted = try decoder.prediction(
                    from: MLDictionaryFeatureProvider(dictionary: [
                        "targets": MLFeatureValue(multiArray: targets),
                        "target_length": MLFeatureValue(multiArray: try CoreMLSupport.scalar(1)),
                        "h_in": MLFeatureValue(multiArray: state.hidden),
                        "c_in": MLFeatureValue(multiArray: state.cell),
                    ]))
                let projection = try CoreMLSupport.output(predicted, "decoder")
                let joined = try joint.prediction(
                    from: MLDictionaryFeatureProvider(dictionary: [
                        parakeet ? "encoder_step" : "encoded": MLFeatureValue(multiArray: encoderStep),
                        parakeet ? "decoder_step" : "decoder": MLFeatureValue(multiArray: projection),
                    ]))
                let token = CoreMLSupport.int(try CoreMLSupport.output(joined, "token_id"))
                if token == blank || token == skipped { break }
                tokens.append(token)
                lastToken = token
                state.hidden = try CoreMLSupport.output(predicted, "h_out")
                state.cell = try CoreMLSupport.output(predicted, "c_out")
            }
        }
        return tokens
    }
}
