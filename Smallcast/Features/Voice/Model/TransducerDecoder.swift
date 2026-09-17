import Foundation

/// The two network calls a transducer step makes; `Service/` binds them to CoreML.
protocol TransducerNetwork {
    associatedtype State

    /// The prediction network: one token in, its projection out, and the LSTM state moved on.
    mutating func predict(token: Int, state: State) throws -> (projection: [Float], state: State)
    /// The joint network at one encoder frame: the argmax token and the duration bin it chose.
    mutating func join(frame: Int, projection: [Float]) throws -> (token: Int, durationBin: Int)
}

/// Greedy token-and-duration decoding over one encoder output. See docs/features/voice.md.
struct TransducerDecoder {
    /// NeMo's own ceiling; past it the model is looping on one frame rather than hearing speech.
    static let maxSymbolsPerFrame = 10

    let blankID: Int
    let durationBins: [Int]

    /// Decoder state carried from one chunk to the next so a word split by the cut still joins.
    struct Carry<State> {
        var state: State
        var lastToken: Int?
        var projection: [Float]?
    }

    /// Decodes `frameCount` encoder frames, appending to `carry` for the next window.
    func decode<Network: TransducerNetwork>(
        frameCount: Int, network: inout Network, carry: inout Carry<Network.State>
    ) throws -> [Int] {
        var tokens: [Int] = []
        guard frameCount > 0 else { return tokens }
        // Blank is the start-of-sequence token: the LSTM has no context until it has heard it.
        if carry.projection == nil {
            let primed = try network.predict(token: carry.lastToken ?? blankID, state: carry.state)
            carry.state = primed.state
            carry.projection = primed.projection
        }
        var frame = 0
        var emittedAtFrame = 0
        while frame < frameCount {
            let step = try network.join(frame: frame, projection: carry.projection!)
            var advance = durationBins.indices.contains(step.durationBin)
                ? durationBins[step.durationBin] : 1
            if step.token == blankID {
                // Silence never changes the language context, so the projection is reused as-is.
                frame += max(advance, 1)
                emittedAtFrame = 0
                continue
            }
            tokens.append(step.token)
            let next = try network.predict(token: step.token, state: carry.state)
            carry.state = next.state
            carry.projection = next.projection
            carry.lastToken = step.token
            if advance == 0 {
                emittedAtFrame += 1
                if emittedAtFrame >= Self.maxSymbolsPerFrame { advance = 1 }
            }
            if advance > 0 { emittedAtFrame = 0 }
            frame += advance
        }
        return tokens
    }
}
