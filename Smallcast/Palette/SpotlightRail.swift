import SwiftUI

/// The Liquid Glass bar's buttons as the surface draws them; the palette decides when they show.
@MainActor
struct SpotlightRail {
    var buttons: [SpotlightButton]
    var isRevealed: Bool
    var activate: (SpotlightButton) -> Void

    static let none = SpotlightRail(buttons: [], isRevealed: false, activate: { _ in })
}

/// Where the capsule ends and each button rests, inside a window exactly as wide as the panel.
@MainActor
struct SpotlightRailGeometry {
    let panelWidth: CGFloat
    let barHeight: CGFloat
    let count: Int
    let gap: CGFloat
    let inset: CGFloat

    init(metrics: InterfaceMetrics, count: Int) {
        panelWidth = metrics.size.panelWidth
        barHeight = metrics.size.compactHeight
        self.count = count
        gap = metrics.scaled(Theme.LiquidGlass.railGap)
        inset = metrics.scaled(Theme.LiquidGlass.railInset)
    }

    var diameter: CGFloat { barHeight - inset * 2 }
    var railWidth: CGFloat { CGFloat(count) * (diameter + gap) }

    func capsuleWidth(revealed: Bool) -> CGFloat {
        revealed ? panelWidth - railWidth : panelWidth
    }

    func center(of index: Int) -> CGPoint {
        CGPoint(
            x: capsuleWidth(revealed: true) + gap + diameter / 2
                + CGFloat(index) * (diameter + gap),
            y: barHeight / 2)
    }

    /// Just inside the revealed capsule's end, so the shortening capsule uncovers each button there.
    var parked: CGPoint {
        CGPoint(x: capsuleWidth(revealed: true) - diameter / 2, y: barHeight / 2)
    }
}

/// The buttons' glass; it must share the capsule's `GlassEffectContainer` to bead off it.
struct SpotlightRailGlass: View {
    let rail: SpotlightRail
    let geometry: SpotlightRailGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(Array(rail.buttons.enumerated()), id: \.element) { index, button in
            let revealed = rail.isRevealed
            let point = revealed ? geometry.center(of: index) : geometry.parked
            Button { rail.activate(button) } label: {
                Color.clear
                    .frame(width: geometry.diameter, height: geometry.diameter)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(button.title)
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(revealed ? 1 : Theme.LiquidGlass.railParkedScale)
            .position(point)
            .allowsHitTesting(revealed)
            .accessibilityHidden(!revealed)
            .animation(
                reduceMotion ? nil : rail.travel(index: index), value: revealed)
        }
    }
}

extension SpotlightRail {
    /// Out in order, back in reverse, so the last one to leave is the first one home.
    func travel(index: Int) -> Animation {
        let step = Theme.LiquidGlass.railStagger
        return isRevealed
            ? Theme.LiquidGlass.railButton.delay(
                Theme.LiquidGlass.railRevealDelay + step * Double(index))
            : Theme.LiquidGlass.railHide.delay(step * Double(buttons.count - 1 - index))
    }
}

/// The glyphs, drawn above the glass rather than inside it, where a morph would smear them.
struct SpotlightRailGlyphs: View {
    let rail: SpotlightRail
    let geometry: SpotlightRailGeometry
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(Array(rail.buttons.enumerated()), id: \.element) { index, button in
            let revealed = rail.isRevealed
            SymbolImage(
                name: button.systemImage, size: metrics.scaled(Theme.LiquidGlass.railGlyphSize),
                monochrome: true)
                .foregroundStyle(Theme.Colors.textSecondary)
                .animation(reduceMotion ? nil : fade(index: index)) {
                    $0.opacity(revealed ? 1 : 0)
                        .blur(radius: revealed ? 0 : Theme.LiquidGlass.railGlyphBlur)
                }
                // Riding its glass, or a glyph would float outside a bubble still on its way.
                .animation(reduceMotion ? nil : rail.travel(index: index)) {
                    $0.scaleEffect(revealed ? 1 : Theme.LiquidGlass.railParkedScale)
                        .position(revealed ? geometry.center(of: index) : geometry.parked)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func fade(index: Int) -> Animation {
        guard rail.isRevealed else { return .easeIn(duration: Theme.LiquidGlass.railGlyphFade / 2) }
        let delay =
            Theme.LiquidGlass.railRevealDelay + Theme.LiquidGlass.railGlyphDelay
            + Theme.LiquidGlass.railStagger * Double(index)
        return .easeOut(duration: Theme.LiquidGlass.railGlyphFade).delay(delay)
    }
}
