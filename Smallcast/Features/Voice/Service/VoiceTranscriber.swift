import CoreML
import Foundation

/// Mono 16 kHz samples in [-1, 1], the one shape every engine takes.
struct VoiceAudio: Sendable {
    static let sampleRate = 16_000
    var samples: [Float]

    var duration: TimeInterval { TimeInterval(samples.count) / TimeInterval(Self.sampleRate) }
}

/// One loaded speech engine. Loading is the expensive half, so a coordinator keeps the instance.
protocol VoiceTranscriber: Sendable {
    func transcribe(_ audio: VoiceAudio, language: VoiceLanguage) async throws -> String
}

enum VoiceTranscriptionError: LocalizedError {
    case modelMissing(String)
    case malformedModel(String)
    case languageRequired
    case unsupportedLanguage(String)
    case speechUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name): return "The \(name) model is not downloaded."
        case .malformedModel(let detail): return "The speech model did not answer as expected: \(detail)."
        case .languageRequired: return "Pick a language for this engine in Settings → AI."
        case .unsupportedLanguage(let code):
            return "This engine does not understand \(VoiceLanguage.named(code).name)."
        case .speechUnavailable(let detail): return detail
        }
    }
}

/// Builds the transcriber for an engine from its downloaded files.
enum VoiceTranscriberFactory {
    /// `root` holds one folder per Hugging Face repo, which is how `VoiceModelStore` lays files out.
    nonisolated static func load(_ engine: VoiceEngine, root: URL) async throws -> any VoiceTranscriber {
        let directory = root.appendingPathComponent(engine.assets?.repo ?? "system", isDirectory: true)
        switch engine.runtime {
        case .appleSpeech:
            return AppleSpeechTranscriber()
        case .transducer(let layout):
            return try await TransducerTranscriber(layout: layout, directory: directory)
        case .streamingTransducer(let layout):
            return try await StreamingTransducerTranscriber(layout: layout, directory: directory)
        case .cohere:
            return try await CohereTranscriber(directory: directory)
        case .whisper:
            guard let tokenizer = engine.assets?.extra.first else {
                throw VoiceTranscriptionError.modelMissing("Whisper tokenizer")
            }
            return try await WhisperTranscriber(
                directory: directory.appendingPathComponent(engine.whisperFolder ?? ""),
                tokenizer: root.appendingPathComponent(tokenizer.repo).appendingPathComponent(tokenizer.path))
        }
    }
}

/// The CoreML plumbing every runner shares.
enum CoreMLSupport {
    /// A `.mlpackage` compiles once into a sibling folder; a `.mlmodelc` loads as it is.
    nonisolated static func load(
        _ name: String, in directory: URL, units: MLComputeUnits
    ) async throws -> MLModel {
        let source = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw VoiceTranscriptionError.modelMissing(name)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let url: URL
        if source.pathExtension == "mlpackage" {
            let compiled = directory.appendingPathComponent("compiled", isDirectory: true)
                .appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let temporary = try await MLModel.compileModel(at: source)
                try FileManager.default.createDirectory(
                    at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporary, to: compiled)
            }
            url = compiled
        } else {
            url = source
        }
        return try await MLModel.load(contentsOf: url, configuration: configuration)
    }

    nonisolated static func array(_ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
        zero(array)
        return array
    }

    nonisolated static func zero(_ array: MLMultiArray) {
        array.withUnsafeMutableBytes { bytes, _ in
            bytes.copyBytes(from: [UInt8](repeating: 0, count: 0))
            memset(bytes.baseAddress, 0, bytes.count)
        }
    }

    nonisolated static func scalar(_ value: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .int32)
        array[0] = NSNumber(value: value)
        return array
    }

    /// The output as Float32 whatever precision the model kept it in.
    nonisolated static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float32:
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        case .float16:
            return array.withUnsafeBufferPointer(ofType: Float16.self) { $0.map(Float.init) }
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    nonisolated static func int(_ array: MLMultiArray) -> Int {
        switch array.dataType {
        case .int32: return array.withUnsafeBufferPointer(ofType: Int32.self) { Int($0[0]) }
        default: return array[0].intValue
        }
    }

    /// Writes Float32 values into an array of either float precision.
    nonisolated static func fill(_ array: MLMultiArray, with values: [Float]) {
        switch array.dataType {
        case .float32:
            array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                for (index, value) in values.enumerated() where index < buffer.count {
                    buffer[index] = value
                }
            }
        case .float16:
            array.withUnsafeMutableBufferPointer(ofType: Float16.self) { buffer, _ in
                for (index, value) in values.enumerated() where index < buffer.count {
                    buffer[index] = Float16(value)
                }
            }
        default:
            for (index, value) in values.enumerated() where index < array.count {
                array[index] = NSNumber(value: value)
            }
        }
    }

    nonisolated static func output(
        _ provider: MLFeatureProvider, _ name: String
    ) throws -> MLMultiArray {
        guard let value = provider.featureValue(for: name)?.multiArrayValue else {
            throw VoiceTranscriptionError.malformedModel("no output named \(name)")
        }
        return value
    }

    nonisolated static func inputType(_ model: MLModel, _ name: String) -> MLMultiArrayDataType {
        model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.dataType
            ?? .float32
    }

    nonisolated static func inputShape(_ model: MLModel, _ name: String) -> [Int] {
        model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape
            .map(\.intValue) ?? []
    }

    nonisolated static func argmax(_ values: [Float]) -> Int {
        var best = 0
        var bestValue = -Float.infinity
        for (index, value) in values.enumerated() where value > bestValue {
            best = index
            bestValue = value
        }
        return best
    }
}

extension MLMultiArray {
    /// Frames `[start, start + count)` of a `[1, bands, T]` mel, zero where the range leaves it.
    func window(from start: Int, count: Int) throws -> MLMultiArray {
        let bands = shape[1].intValue
        let frames = shape[2].intValue
        let strides = self.strides.map(\.intValue)
        let out = try CoreMLSupport.array([1, bands, count], .float32)
        let source = CoreMLSupport.floats(self)
        out.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for band in 0..<bands {
                for offset in 0..<count {
                    let frame = start + offset
                    guard frame >= 0, frame < frames else { continue }
                    buffer[band * count + offset] = source[band * strides[1] + frame * strides[2]]
                }
            }
        }
        return out
    }
}
