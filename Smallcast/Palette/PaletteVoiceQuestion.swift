import SwiftUI

/// Stands in for the search field while a question is dictated; the field stays mounted beneath.
struct PaletteVoiceField: ViewModifier {
    let font: Font
    @Environment(AppCore.self) private var core
    @Environment(PaletteState.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let question = vm.holdsVoiceQuestion ? nil : core.dictationCoordinator.question
        // The search text leaves with the buttons; the readout waits for Quick AI, once they fuse.
        let readout = vm.mode == .ai ? question : nil
        let fade: Animation? = reduceMotion ? nil : .easeOut(duration: Theme.Duration.voiceQuestion)
        content
            .animation(fade) { $0.opacity(question == nil ? 1 : 0) }
            .overlay {
                // Scoped to the readout: on the field, it would animate the answer's screen arriving.
                ZStack {
                    if let readout {
                        VoiceReadout(state: readout, font: font)
                            .transition(.opacity)
                    }
                }
                .animation(fade, value: readout != nil)
            }
    }
}

private struct VoiceReadout: View {
    let state: DictationDisplayState
    let font: Font
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let listening = state.phase == .listening
        HStack(spacing: metrics.spacing.md) {
            Text(listening ? "Listening…" : "Transcribing…")
                .font(font)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "waveform", variableValue: listening ? loudness : 1)
                .font(metrics.typography.headerIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Colors.textSecondary)
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers,
                    options: .repeating, isActive: !listening && !reduceMotion)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            listening ? "Listening for a question to ask AI" : "Transcribing your question")
    }

    /// The loudest band, so the symbol lifts with the voice rather than with its average.
    private var loudness: Double {
        Double(min(1, state.levels.max() ?? 0))
    }
}
