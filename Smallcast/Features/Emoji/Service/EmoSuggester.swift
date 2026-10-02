import CoreML
import Foundation

/// The loaded Emo classifier; `MLModel` predicts thread-safely and nothing mutates after `init`.
final class EmoSuggester: @unchecked Sendable {
    enum Failure: LocalizedError {
        case missingOutput

        var errorDescription: String? { "The model returned no probabilities." }
    }

    private let model: MLModel
    private let meta: EmoMeta
    private let tokenizer: EmoSemanticTokenizer

    /// Reads the sidecars and compiles the model; slow enough to belong in `Task.detached`.
    nonisolated init(directory: URL) throws {
        meta = try EmoMeta(json: Data(contentsOf: directory.appendingPathComponent("emo_meta.json")))
        let bytes = [UInt8](try Data(contentsOf: directory.appendingPathComponent("emo_tokenizer.bin")))
        guard let tokenizer = EmoSemanticTokenizer(bytes: bytes) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.tokenizer = tokenizer
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        model = try MLModel(
            contentsOf: directory.appendingPathComponent("emo.mlmodelc"), configuration: configuration)
    }

    nonisolated func suggest(
        _ text: String, limit: Int, minimumConfidence: Double
    ) throws -> [EmoSuggestion] {
        let inputs = EmoModelInputs(text: text, meta: meta, tokenizer: tokenizer)
        let window = meta.featureWindow
        let hashes = meta.hashes
        let semantic = meta.semanticWindow
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "ngram_buckets": try Self.array(inputs.ngramBuckets, shape: [1, window, hashes]),
            "ngram_signs": try Self.array(inputs.ngramSigns, shape: [1, window, hashes]),
            "ngram_importance": try Self.array(inputs.ngramImportance, shape: [1, window]),
            "ngram_count": try Self.array([inputs.ngramCount], shape: [1, 1]),
            "sem_ids": try Self.array(inputs.semanticIDs, shape: [1, semantic]),
            "sem_mask": try Self.array(inputs.semanticMask, shape: [1, semantic])
        ])
        let output = try model.prediction(from: provider)
        guard let probabilities = output.featureValue(for: "probabilities")?.multiArrayValue else {
            throw Failure.missingOutput
        }
        return EmoRanking.rank(
            probabilities: Self.floats(probabilities), labels: meta.labels, limit: limit,
            minimumConfidence: minimumConfidence)
    }

    private nonisolated static func array(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        array.withUnsafeMutableBytes { pointer, _ in
            values.withUnsafeBytes { pointer.copyMemory(from: $0) }
        }
        return array
    }

    private nonisolated static func array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        array.withUnsafeMutableBytes { pointer, _ in
            values.withUnsafeBytes { pointer.copyMemory(from: $0) }
        }
        return array
    }

    /// The export emits Float16; a contiguous read beats `NSNumber` subscripting per label.
    private nonisolated static func floats(_ array: MLMultiArray) -> [Float] {
        var values = [Float](repeating: 0, count: array.count)
        array.withUnsafeBytes { raw in
            switch array.dataType {
            case .float16:
                let pointer = raw.bindMemory(to: Float16.self)
                for i in values.indices { values[i] = Float(pointer[i]) }
            case .float32:
                let pointer = raw.bindMemory(to: Float.self)
                for i in values.indices { values[i] = pointer[i] }
            default:
                for i in values.indices { values[i] = array[i].floatValue }
            }
        }
        return values
    }
}
