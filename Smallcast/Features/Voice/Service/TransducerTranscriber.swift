import CoreML
import Foundation

/// Parakeet TDT and the offline Nemotron: preprocessor → encoder → greedy transducer decode.
final class TransducerTranscriber: VoiceTranscriber, @unchecked Sendable {
    private let layout: TransducerLayout
    private let preprocessor: MLModel
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: SentencePieceVocabulary
    private let prompts: [String: Int]
    private let promptCount: Int

    nonisolated init(layout: TransducerLayout, directory: URL) async throws {
        self.layout = layout
        // The encoder is the only heavy graph; the LSTM and joint run faster without an ANE hop.
        let encoderUnits: MLComputeUnits = layout.family == .nemotron ? .cpuOnly : .cpuAndNeuralEngine
        preprocessor = try await CoreMLSupport.load(layout.preprocessor, in: directory, units: .cpuOnly)
        encoder = try await CoreMLSupport.load(layout.encoder, in: directory, units: encoderUnits)
        decoder = try await CoreMLSupport.load(layout.decoder, in: directory, units: .cpuOnly)
        joint = try await CoreMLSupport.load(layout.joint, in: directory, units: .cpuOnly)
        let vocabularyData = try Data(contentsOf: directory.appendingPathComponent(layout.vocabulary))
        switch layout.family {
        case .parakeet:
            vocabulary = try SentencePieceVocabulary(json: vocabularyData)
            prompts = [:]
            promptCount = 0
        case .nemotron:
            vocabulary = try SentencePieceVocabulary(sentencePieceModel: vocabularyData)
            let metadata = try NemotronMetadata(
                contentsOf: directory.appendingPathComponent("metadata.json"))
            prompts = metadata.prompts
            promptCount = metadata.promptCount
        }
    }

    func transcribe(_ audio: VoiceAudio, language: VoiceLanguage) async throws -> String {
        var carry = TransducerDecoder.Carry<TransducerState>(
            state: try TransducerState(layers: layout.decoderLayers), lastToken: nil, projection: nil)
        let decode = TransducerDecoder(blankID: layout.blankID, durationBins: layout.durationBins)
        var tokens: [Int] = []
        var start = 0
        while start < audio.samples.count {
            let end = min(start + layout.maxSamples, audio.samples.count)
            let window = Array(audio.samples[start..<end])
            start = end
            let encoded = try encode(window, language: language)
            var network = CoreMLTransducerNetwork(
                decoder: decoder, joint: joint, layout: layout, encoded: encoded)
            tokens += try decode.decode(
                frameCount: encoded.frames, network: &network, carry: &carry)
            try Task.checkCancellation()
        }
        return vocabulary.text(for: tokens)
    }

    private func encode(_ samples: [Float], language: VoiceLanguage) throws -> EncodedAudio {
        var padded = samples
        if layout.family == .parakeet, padded.count < layout.maxSamples {
            padded += [Float](repeating: 0, count: layout.maxSamples - padded.count)
        }
        let signal = try CoreMLSupport.array([1, padded.count], .float32)
        CoreMLSupport.fill(signal, with: padded)
        let melOutput = try preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "audio_signal": MLFeatureValue(multiArray: signal),
                "audio_length": MLFeatureValue(multiArray: try CoreMLSupport.scalar(samples.count)),
            ]))
        let features: [String: MLFeatureValue]
        let encodedName: String
        let lengthName: String
        switch layout.family {
        case .parakeet:
            features = [
                "mel": MLFeatureValue(multiArray: try CoreMLSupport.output(melOutput, "mel")),
                "mel_length": MLFeatureValue(
                    multiArray: try CoreMLSupport.output(melOutput, "mel_length")),
            ]
            encodedName = "encoder"
            lengthName = "encoder_length"
        case .nemotron:
            let prompt = try CoreMLSupport.array([1, promptCount], .float32)
            prompt[promptID(for: language)] = 1
            // The batch encoder is exported for a fixed 15 s mel; shorter audio is zero-padded.
            let mel = try CoreMLSupport.output(melOutput, "processed_signal")
            let wanted = CoreMLSupport.inputShape(encoder, "processed_signal").last ?? mel.shape[2].intValue
            features = [
                "processed_signal": MLFeatureValue(multiArray: try mel.window(from: 0, count: wanted)),
                "processed_signal_length": MLFeatureValue(
                    multiArray: try CoreMLSupport.output(melOutput, "processed_signal_length")),
                "prompt_vector": MLFeatureValue(multiArray: prompt),
            ]
            encodedName = "encoded"
            lengthName = "encoded_len"
        }
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        let encoded = try CoreMLSupport.output(output, encodedName)
        let frames = CoreMLSupport.int(try CoreMLSupport.output(output, lengthName))
        return EncodedAudio(array: encoded, frames: min(frames, encoded.shape[2].intValue))
    }

    /// `auto` unless the picked language is one the model was trained with a prompt for.
    private func promptID(for language: VoiceLanguage) -> Int {
        let auto = prompts["auto"] ?? 0
        guard !language.isAuto else { return auto }
        if let exact = prompts[language.code] { return exact }
        let region = prompts.first { VoiceLanguage.base(of: $0.key) == language.code }
        return region?.value ?? auto
    }
}

/// One encoder pass: `[1, hidden, T]`, channels first, so a frame is a strided column.
struct EncodedAudio: @unchecked Sendable {
    let array: MLMultiArray
    let frames: Int

    var hidden: Int { array.shape[1].intValue }

    func frame(_ index: Int) -> [Float] {
        let strides = array.strides.map(\.intValue)
        let hidden = self.hidden
        var out = [Float](repeating: 0, count: hidden)
        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                for channel in 0..<hidden {
                    out[channel] = buffer[channel * strides[1] + index * strides[2]]
                }
            }
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                for channel in 0..<hidden {
                    out[channel] = Float(buffer[channel * strides[1] + index * strides[2]])
                }
            }
        default:
            for channel in 0..<hidden {
                out[channel] = array[[0, channel, index] as [NSNumber]].floatValue
            }
        }
        return out
    }
}

/// The LSTM hidden and cell tensors, `[layers, 1, 640]`.
struct TransducerState: @unchecked Sendable {
    var hidden: MLMultiArray
    var cell: MLMultiArray

    init(layers: Int) throws {
        hidden = try CoreMLSupport.array([layers, 1, 640], .float32)
        cell = try CoreMLSupport.array([layers, 1, 640], .float32)
    }
}

/// Binds `TransducerDecoder`'s two calls to the CoreML decoder and joint models.
struct CoreMLTransducerNetwork: TransducerNetwork {
    let decoder: MLModel
    let joint: MLModel
    let layout: TransducerLayout
    let encoded: EncodedAudio

    /// Whether the joint speaks Parakeet (`encoder_step`/`decoder_step`) or Nemotron names.
    private var parakeet: Bool { layout.family == .parakeet }

    mutating func predict(token: Int, state: TransducerState) throws -> (projection: [Float], state: TransducerState) {
        let targets = try CoreMLSupport.array([1, 1], .int32)
        targets[0] = NSNumber(value: token)
        let output = try decoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "targets": MLFeatureValue(multiArray: targets),
                "target_length": MLFeatureValue(multiArray: try CoreMLSupport.scalar(1)),
                "h_in": MLFeatureValue(multiArray: state.hidden),
                "c_in": MLFeatureValue(multiArray: state.cell),
            ]))
        var next = state
        next.hidden = try CoreMLSupport.output(output, "h_out")
        next.cell = try CoreMLSupport.output(output, "c_out")
        return (CoreMLSupport.floats(try CoreMLSupport.output(output, "decoder")), next)
    }

    mutating func join(frame: Int, projection: [Float]) throws -> (token: Int, durationBin: Int) {
        let encoderStep = try CoreMLSupport.array([1, encoded.hidden, 1], .float32)
        CoreMLSupport.fill(encoderStep, with: encoded.frame(frame))
        let decoderStep = try CoreMLSupport.array([1, projection.count, 1], .float32)
        CoreMLSupport.fill(decoderStep, with: projection)
        let output = try joint.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                parakeet ? "encoder_step" : "encoded": MLFeatureValue(multiArray: encoderStep),
                parakeet ? "decoder_step" : "decoder": MLFeatureValue(multiArray: decoderStep),
            ]))
        let token = CoreMLSupport.int(try CoreMLSupport.output(output, "token_id"))
        let duration =
            output.featureValue(for: "duration")?.multiArrayValue.map(CoreMLSupport.int) ?? 0
        return (token, duration)
    }
}

/// The prompt table a Nemotron export ships beside its models.
struct NemotronMetadata {
    let prompts: [String: Int]
    let promptCount: Int
    let blankID: Int
    /// New mel frames per encoder call for a streaming export; the batch export has none.
    let streamingShiftFrames: Int

    init(contentsOf url: URL) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let json = object as? [String: Any] else {
            throw VoiceTranscriptionError.malformedModel("metadata.json is not an object")
        }
        prompts = json["prompt_dictionary"] as? [String: Int] ?? ["auto": 101]
        promptCount = json["num_prompts"] as? Int ?? 128
        blankID = json["blank_idx"] as? Int ?? 13_087
        let streaming = json["streaming"] as? [String: Any]
        streamingShiftFrames = (streaming?["shift_size"] as? [Int])?.last ?? 32
    }
}
