import SwiftUI

/// The chat body while a hold is in flight: a level meter, then a note that the engine is at work.
struct VoiceListeningView: View {
    @Environment(\.metrics) private var metrics
    let session: VoiceSession

    var body: some View {
        VStack(spacing: metrics.spacing.lg) {
            meter
            VStack(spacing: metrics.spacing.xs) {
                Text(title)
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(detail)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, metrics.spacing.xxl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch session.phase {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .idle: return ""
        }
    }

    private var detail: String {
        switch session.phase {
        case .listening: return "Release the shortcut to send what you said."
        case .transcribing: return session.engine.map { "\($0.title) is turning it into text." } ?? ""
        case .idle: return ""
        }
    }

    /// One bar per recent level reading, newest at the right, so speech visibly moves.
    private var meter: some View {
        HStack(alignment: .center, spacing: metrics.spacing.xs) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: metrics.radius.glyph, style: .continuous)
                    .fill(session.phase == .listening ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                    .frame(width: metrics.spacing.xs, height: max(metrics.spacing.xs, CGFloat(level) * meterHeight))
            }
        }
        .frame(height: meterHeight)
        .animation(.linear(duration: 0.06), value: session.levels)
    }

    private var bars: [Float] {
        let levels = session.levels
        guard levels.count < VoiceSession.meterBars else { return levels }
        return [Float](repeating: 0, count: VoiceSession.meterBars - levels.count) + levels
    }

    private var meterHeight: CGFloat { metrics.size.rowIcon * 2 }
}
