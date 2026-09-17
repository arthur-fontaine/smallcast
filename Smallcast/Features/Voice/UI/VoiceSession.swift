import Foundation
import Observation

/// What the palette shows while a hold is in flight; `AppCore` owns it so a view can never lose it.
@MainActor
@Observable
final class VoiceSession {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
    }

    private(set) var phase: Phase = .idle
    /// The engine at work, so the screen can say which one is thinking.
    private(set) var engine: VoiceEngine?
    /// Recent microphone levels, newest last, for the meter.
    private(set) var levels: [Float] = []

    static let meterBars = 28

    func listen(with engine: VoiceEngine) {
        self.engine = engine
        levels = [Float](repeating: 0, count: Self.meterBars)
        phase = .listening
    }

    func heard(_ level: Float) {
        guard phase == .listening else { return }
        levels.append(level)
        if levels.count > Self.meterBars { levels.removeFirst(levels.count - Self.meterBars) }
    }

    func transcribe() {
        phase = .transcribing
    }

    func reset() {
        phase = .idle
        engine = nil
        levels = []
    }

    var isActive: Bool { phase != .idle }
}
