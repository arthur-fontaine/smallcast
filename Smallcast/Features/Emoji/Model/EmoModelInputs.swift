import Foundation

/// The `emo_meta.json` sidecar: label order and the featurizer constants the export was built with.
struct EmoMeta: Decodable, Sendable {
    let labels: [String]
    let hashes: Int
    let buckets: Int
    let importance: Int
    let semanticPadIndex: Int
    let featureWindow: Int
    let semanticWindow: Int

    enum CodingKeys: String, CodingKey {
        case labels
        case hashes = "n_hashes"
        case buckets = "n_buckets"
        case importance = "n_importance"
        case semanticPadIndex = "sem_pad_index"
        case featureWindow = "fmax"
        case semanticWindow = "smax"
    }

    init(json: Data) throws {
        self = try JSONDecoder().decode(EmoMeta.self, from: json)
    }
}

/// The six fixed-window tensors Emo's Core ML export takes, flattened row-major.
struct EmoModelInputs: Equatable, Sendable {
    let ngramBuckets: [Int32]
    let ngramSigns: [Float]
    let ngramImportance: [Int32]
    let ngramCount: Float
    let semanticIDs: [Int32]
    let semanticMask: [Float]

    init(text: String, meta: EmoMeta, tokenizer: EmoSemanticTokenizer) {
        let window = meta.featureWindow
        let hashes = meta.hashes
        let features = EmoNGramEncoder.encode(
            text, buckets: UInt32(meta.buckets), hashes: hashes,
            importance: UInt32(meta.importance), maxFeatures: window)
        let count = min(features.count, window)

        var buckets = [Int32](repeating: 0, count: window * hashes)
        var signs = [Float](repeating: 0, count: window * hashes)
        var importance = [Int32](repeating: 0, count: window)
        for f in 0..<count {
            importance[f] = features.importance[f]
            for k in 0..<hashes {
                buckets[f * hashes + k] = features.buckets[f][k]
                signs[f * hashes + k] = features.signs[f][k]
            }
        }
        ngramBuckets = buckets
        ngramSigns = signs
        ngramImportance = importance
        ngramCount = Float(max(count, 1))

        let ids = Array(tokenizer.encode(text).prefix(meta.semanticWindow))
        var semanticIDs = [Int32](repeating: Int32(meta.semanticPadIndex), count: meta.semanticWindow)
        var semanticMask = [Float](repeating: 0, count: meta.semanticWindow)
        if ids.isEmpty {
            // The export keeps one padded position unmasked so the pool never sees an all-masked row.
            semanticMask[0] = 1
        } else {
            for i in ids.indices {
                semanticIDs[i] = ids[i]
                semanticMask[i] = 1
            }
        }
        self.semanticIDs = semanticIDs
        self.semanticMask = semanticMask
    }
}

/// One ranked emoji from the classifier; `glyph` is the label string as the model emits it.
struct EmoSuggestion: Hashable, Sendable {
    let glyph: String
    let confidence: Double
}

enum EmoRanking {
    /// Labels paired with their probabilities, most likely first, with the noise floor dropped.
    static func rank(
        probabilities: [Float], labels: [String], limit: Int, minimumConfidence: Double
    ) -> [EmoSuggestion] {
        var scored: [EmoSuggestion] = []
        scored.reserveCapacity(min(labels.count, probabilities.count))
        for i in 0..<min(labels.count, probabilities.count) {
            let confidence = Double(probabilities[i])
            guard confidence >= minimumConfidence else { continue }
            scored.append(EmoSuggestion(glyph: labels[i], confidence: confidence))
        }
        return Array(scored.sorted { $0.confidence > $1.confidence }.prefix(max(0, limit)))
    }
}
