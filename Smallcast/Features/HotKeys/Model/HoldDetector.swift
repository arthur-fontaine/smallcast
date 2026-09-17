import Foundation

/// Tells a held toggle chord from a tapped one. See docs/features/hotkeys.md#hold-to-talk.
struct HoldDetector {
    /// Long enough that a deliberate tap never trips it; short enough to feel like push-to-talk.
    static let threshold: TimeInterval = 0.45

    enum Release: Equatable, Sendable {
        case tap
        case hold
    }

    private(set) var pressedAt: TimeInterval?
    private(set) var isHolding = false

    /// False for a repeat while the key is already down, so a held key never re-fires the press.
    mutating func press(at now: TimeInterval) -> Bool {
        guard pressedAt == nil else { return false }
        pressedAt = now
        isHolding = false
        return true
    }

    /// The caller's timer asks at the threshold; true exactly once, when the hold begins.
    mutating func elapse(at now: TimeInterval) -> Bool {
        guard let pressedAt, !isHolding, now - pressedAt >= Self.threshold else { return false }
        isHolding = true
        return true
    }

    /// Nil for a release with no press in flight — Carbon can deliver one after a pause resumes.
    mutating func release(at now: TimeInterval) -> Release? {
        guard pressedAt != nil else { return nil }
        let held = isHolding
        pressedAt = nil
        isHolding = false
        return held ? .hold : .tap
    }

    mutating func reset() {
        pressedAt = nil
        isHolding = false
    }
}
