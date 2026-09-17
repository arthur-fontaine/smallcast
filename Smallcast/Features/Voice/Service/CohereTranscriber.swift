import Accelerate
import CoreML
import Foundation

/// Cohere Transcribe: a Conformer encoder over a 35 s mel, then a cached transformer decoder.
final class CohereTranscriber: VoiceTranscriber, @unchecked Sendable {
    private static let melFrames = 3_500
    private static let windowSamples = melFrames * 160
    private static let layers = 8
    private static let contextLength = 108
    private let encoder: MLModel
    private let decoder: MLModel
    private let vocabulary: SentencePieceVocabulary
    private let cacheType: MLMultiArrayDataType
    private let cacheShape: [Int]
    private let staticMask: Bool

    /// Special ids from the export's vocabulary; the prompt is what the reference pipeline sends.
    private enum Token {
        static let endOfText = 3
        static let wordBoundary = 13_764
        static let startOfContext = 7
        static let startOfTranscript = 4
        static let emotionUndefined = 16
        static let punctuation = 5
        static let noNormalization = 9
        static let noTimestamps = 11
        static let noDiarization = 13
    }

    private static let languageTokens: [String: Int] = [
        "en": 62, "fr": 69, "de": 76, "es": 169, "it": 97, "pt": 149, "nl": 60, "pl": 148,
        "el": 77, "ar": 28, "ja": 98, "zh": 50, "vi": 194, "ko": 110,
    ]

    nonisolated init(directory: URL) async throws {
        let q8 = directory.appendingPathComponent("q8")
        encoder = try await CoreMLSupport.load("cohere_encoder.mlmodelc", in: q8, units: .cpuAndNeuralEngine)
        decoder = try await CoreMLSupport.load(
            "cohere_decoder_cache_external_v2.mlmodelc", in: q8, units: .all)
        vocabulary = try SentencePieceVocabulary(
            json: Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        cacheShape = CoreMLSupport.inputShape(decoder, "k_cache_0")
        cacheType = CoreMLSupport.inputType(decoder, "k_cache_0")
        // The v2 export attends over the whole cache and needs unwritten slots masked out.
        staticMask = (CoreMLSupport.inputShape(decoder, "attention_mask").last ?? 0) > 1
    }

    func transcribe(_ audio: VoiceAudio, language: VoiceLanguage) async throws -> String {
        guard !language.isAuto else { throw VoiceTranscriptionError.languageRequired }
        guard let languageToken = Self.languageTokens[language.code] else {
            throw VoiceTranscriptionError.unsupportedLanguage(language.code)
        }
        var pieces: [String] = []
        var start = 0
        repeat {
            let end = min(start + Self.windowSamples, audio.samples.count)
            let window = Array(audio.samples[start..<end])
            start = end
            let (hidden, validFrames) = try encode(window)
            let tokens = try decode(hidden, validFrames: validFrames, languageToken: languageToken)
            pieces.append(vocabulary.text(for: tokens))
            try Task.checkCancellation()
        } while start < audio.samples.count
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func encode(_ samples: [Float]) throws -> (MLMultiArray, Int) {
        let mel = CohereMelSpectrogram.compute(samples)
        let features = try CoreMLSupport.array([1, CohereMelSpectrogram.bands, Self.melFrames], .float32)
        features.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for band in 0..<CohereMelSpectrogram.bands {
                for frame in 0..<min(mel.frames, Self.melFrames) {
                    buffer[band * Self.melFrames + frame] = mel.values[band * mel.stride + frame]
                }
            }
        }
        let output = try encoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                "input_features": MLFeatureValue(multiArray: features),
                "feature_length": MLFeatureValue(multiArray: try CoreMLSupport.scalar(mel.frames)),
            ]))
        let hidden = try CoreMLSupport.output(output, "hidden_states")
        let encoderFrames = hidden.shape[1].intValue
        let valid = Int((Double(mel.frames * encoderFrames) / Double(Self.melFrames)).rounded(.up))
        return (hidden, max(1, min(valid, encoderFrames)))
    }

    private func decode(_ hidden: MLMultiArray, validFrames: Int, languageToken: Int) throws -> [Int] {
        let prompt = [
            Token.wordBoundary, Token.startOfContext, Token.startOfTranscript, Token.emotionUndefined,
            languageToken, languageToken, Token.punctuation, Token.noNormalization,
            Token.noTimestamps, Token.noDiarization,
        ]
        var keys: [MLMultiArray] = []
        var values: [MLMultiArray] = []
        for _ in 0..<Self.layers {
            keys.append(try CoreMLSupport.array(cacheShape, cacheType))
            values.append(try CoreMLSupport.array(cacheShape, cacheType))
        }
        let encoderFrames = hidden.shape[1].intValue
        let crossMask = try CoreMLSupport.array([1, 1, 1, encoderFrames], cacheType)
        CoreMLSupport.fill(
            crossMask,
            with: (0..<encoderFrames).map { $0 < validFrames ? 0 : -10_000 })
        var history: [Int] = []
        var produced: [Int] = []
        var current = prompt[0]
        for step in 0..<Self.contextLength {
            let inputID = try CoreMLSupport.array([1, 1], .int32)
            inputID[0] = NSNumber(value: current)
            let position = try CoreMLSupport.array([1, 1], .int32)
            position[0] = NSNumber(value: step)
            let selfMask: MLMultiArray
            if staticMask {
                selfMask = try CoreMLSupport.array([1, 1, 1, Self.contextLength], cacheType)
                CoreMLSupport.fill(
                    selfMask, with: (0..<Self.contextLength).map { $0 <= step ? 0 : -10_000 })
            } else {
                selfMask = try CoreMLSupport.array([1, 1, 1, step + 1], cacheType)
            }
            var inputs: [String: MLFeatureValue] = [
                "input_id": MLFeatureValue(multiArray: inputID),
                "position_id": MLFeatureValue(multiArray: position),
                "encoder_hidden_states": MLFeatureValue(multiArray: hidden),
                "cross_attention_mask": MLFeatureValue(multiArray: crossMask),
                "attention_mask": MLFeatureValue(multiArray: selfMask),
            ]
            for layer in 0..<Self.layers {
                inputs["k_cache_\(layer)"] = MLFeatureValue(multiArray: keys[layer])
                inputs["v_cache_\(layer)"] = MLFeatureValue(multiArray: values[layer])
            }
            let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
            for layer in 0..<Self.layers {
                keys[layer] = try CoreMLSupport.output(output, "k_cache_\(layer)_out")
                values[layer] = try CoreMLSupport.output(output, "v_cache_\(layer)_out")
            }
            history.append(current)
            var logits = CoreMLSupport.floats(try CoreMLSupport.output(output, "logits"))
            Self.penalizeRepeats(&logits, history: history)
            let next = CoreMLSupport.argmax(logits)
            if step < prompt.count - 1 {
                current = prompt[step + 1]
                continue
            }
            if next == Token.endOfText { break }
            produced.append(next)
            current = next
        }
        return produced
    }

    /// The reference pipeline's repetition penalty and three-gram block, so a loop cannot run away.
    private static func penalizeRepeats(_ logits: inout [Float], history: [Int]) {
        for token in Set(history) where token < logits.count {
            logits[token] = logits[token] >= 0 ? logits[token] / 1.1 : logits[token] * 1.1
        }
        guard history.count >= 2 else { return }
        let tail = Array(history.suffix(2))
        for index in 0..<(history.count - 2) where Array(history[index..<index + 2]) == tail {
            let banned = history[index + 2]
            if banned < logits.count { logits[banned] = -1e9 }
        }
    }
}

/// NeMo's log-mel front end as Cohere's checkpoint expects it: 128 Slaney bands, CMVN per band.
enum CohereMelSpectrogram {
    static let bands = 128
    private static let fftSize = 512
    private static let windowLength = 400
    private static let hop = 160
    private static let preemphasis: Float = 0.97

    struct Output {
        /// `[bands × stride]`, band-major; only the first `frames` of each row hold audio.
        let values: [Float]
        let stride: Int
        let frames: Int
    }

    private static let window: [Float] = {
        var hann = [Float](repeating: 0, count: fftSize)
        let pad = (fftSize - windowLength) / 2
        for index in 0..<windowLength {
            hann[pad + index] = 0.5 * (1 - cos(2 * .pi * Float(index) / Float(windowLength - 1)))
        }
        return hann
    }()

    private static let filterbank: [[Float]] = {
        let bins = fftSize / 2 + 1
        func toMel(_ hz: Float) -> Float {
            hz >= 1_000 ? 15 + log(hz / 1_000) / 0.06875177742 : hz / (200 / 3)
        }
        func toHz(_ mel: Float) -> Float {
            mel >= 15 ? 1_000 * exp(0.06875177742 * (mel - 15)) : (200 / 3) * mel
        }
        let low = toMel(0)
        let high = toMel(8_000)
        let points = (0..<bands + 2).map { toHz(low + Float($0) * (high - low) / Float(bands + 1)) }
        return (0..<bands).map { band in
            let lower = points[band]
            let center = points[band + 1]
            let upper = points[band + 2]
            let norm = 2 / max(upper - lower, 1e-10)
            return (0..<bins).map { bin in
                let hz = 16_000 * Float(bin) / Float(fftSize)
                guard hz >= lower, hz <= upper else { return 0 }
                let weight =
                    hz <= center
                    ? (hz - lower) / max(center - lower, 1e-10) : (upper - hz) / max(upper - center, 1e-10)
                return weight * norm
            }
        }
    }()

    /// `values` is `[bands × frames]`, band-major; `frames` is what the encoder should count.
    static func compute(_ audio: [Float]) -> Output {
        let validFrames = audio.count / hop
        var samples = audio
        for index in stride(from: samples.count - 1, to: 0, by: -1) {
            samples[index] -= preemphasis * samples[index - 1]
        }
        let pad = fftSize / 2
        let padded = [Float](repeating: 0, count: pad) + samples + [Float](repeating: 0, count: pad)
        let frames = 1 + (padded.count - fftSize) / hop
        let bins = fftSize / 2 + 1
        var power = [Float](repeating: 0, count: bins * frames)
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return Output(values: [], stride: 0, frames: 0)
        }
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: fftSize)
        for index in 0..<frames {
            let start = index * hop
            vDSP.multiply(padded[start..<start + fftSize], window, result: &frame)
            frame.withUnsafeBufferPointer { input in
                input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                    real.withUnsafeMutableBufferPointer { realBuffer in
                        imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                            var split = DSPSplitComplex(
                                realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                            fft.forward(input: split, output: &split)
                        }
                    }
                }
            }
            // vDSP packs DC and Nyquist into bin 0, and its forward FFT is 2× numpy's.
            power[index] = pow(real[0] * 0.5, 2)
            power[(bins - 1) * frames + index] = pow(imaginary[0] * 0.5, 2)
            for bin in 1..<half {
                let re = real[bin] * 0.5
                let im = imaginary[bin] * 0.5
                power[bin * frames + index] = re * re + im * im
            }
        }
        var mel = [Float](repeating: 0, count: bands * frames)
        for band in 0..<bands {
            let filter = filterbank[band]
            for index in 0..<frames {
                var sum: Float = 0
                for bin in 0..<bins where filter[bin] != 0 { sum += filter[bin] * power[bin * frames + index] }
                mel[band * frames + index] = log(sum + 5.960_464_5e-08)
            }
        }
        let counted = min(validFrames, frames)
        if counted > 1 {
            for band in 0..<bands {
                let row = band * frames
                var mean: Float = 0
                for index in 0..<counted { mean += mel[row + index] }
                mean /= Float(counted)
                var variance: Float = 0
                for index in 0..<counted { variance += pow(mel[row + index] - mean, 2) }
                let deviation = sqrt(variance / Float(counted - 1))
                let scale = 1 / ((deviation.isFinite ? deviation : 0) + 1e-5)
                for index in 0..<counted { mel[row + index] = (mel[row + index] - mean) * scale }
                for index in counted..<frames { mel[row + index] = 0 }
            }
        }
        return Output(values: mel, stride: frames, frames: counted)
    }
}
