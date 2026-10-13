import SwiftUI

/// The palette's backdrop, corner and arrival, per theme; nothing drawn above it branches on theme.
struct PaletteSurface: ViewModifier {
    let isDimmed: Bool
    let presentation: PalettePresentation
    var rail: SpotlightRail = .none
    var glassHeight: CGFloat?
    var contentHeight: CGFloat?
    @Environment(\.paletteTheme) private var theme
    @Environment(\.metrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        switch theme {
        case .smallcast:
            dimmable(
                content
                    .background(Theme.Colors.panelScrim)
                    .background(GlassEffectView())
            )
            .clipShape(RoundedRectangle(cornerRadius: metrics.radius.panel, style: .continuous))
        case .liquidGlass:
            let shape = PaletteSurface.liquidGlassShape(metrics)
            let geometry = SpotlightRailGeometry(metrics: metrics, count: rail.buttons.count)
            let width = geometry.capsuleWidth(revealed: rail.isRevealed)
            ZStack(alignment: .topLeading) {
                // One container, or the buttons could never bead off the capsule they come out of.
                GlassEffectContainer(spacing: metrics.scaled(Theme.LiquidGlass.railBlend)) {
                    ZStack(alignment: .topLeading) {
                        // Only the glass rides the spring: on the content, it animated every change.
                        shape.fill(Theme.Colors.glassScrim)
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                            .glassEffect(.regular, in: shape)
                            .animation(capsuleMotion, value: rail.isRevealed)
                        SpotlightRailGlass(rail: rail, geometry: geometry)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Handed the card's spring, glass re-runs it on each frame's size and falls behind.
                    .transaction { $0.animation = nil }
                }
                // Glass casts a soft shadow; unclipped, the window's square corners show it as a tint.
                .clipShape(shape)
                .overlay(alignment: .topLeading) { SpotlightRailGlyphs(rail: rail, geometry: geometry) }
                .frame(height: glassHeight, alignment: .top)
                // Narrowed with the capsule, so the field never runs under a button.
                dimmable(content.frame(width: width))
                    .frame(height: contentHeight, alignment: .top)
                    // Sized by that height, not the rows': squeezed, they overflow it.
                    .mask(alignment: .topLeading) {
                        shape
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                            .animation(capsuleMotion, value: rail.isRevealed)
                    }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .scaleEffect(x: presentationScale, y: 1)
        }
    }

    /// Shortening waits out the buttons' reveal delay, so they extrude as the capsule pulls back.
    private var capsuleMotion: Animation? {
        guard !reduceMotion else { return nil }
        return rail.isRevealed
            ? Theme.LiquidGlass.railReveal.delay(Theme.LiquidGlass.railRevealDelay)
            : Theme.LiquidGlass.railHide
    }

    /// The compact bar's own capsule radius, kept as the card grows so its ends become its corners.
    static func liquidGlassShape(_ metrics: InterfaceMetrics) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.size.compactHeight / 2, style: .continuous)
    }

    private var presentationScale: CGFloat {
        switch presentation {
        case .entering: Theme.LiquidGlass.enterScale
        case .shown: 1
        case .exiting: Theme.LiquidGlass.exitScale
        }
    }

    private func dimmable(_ content: some View) -> some View {
        content
            .overlay {
                Theme.Colors.dialogDimming
                    .opacity(isDimmed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(
                .easeOut(duration: isDimmed ? Theme.Duration.dialogEnter : Theme.Duration.dialogExit),
                value: isDimmed
            )
    }
}

/// A footer control's surface: clear glass on Smallcast's scrim, regular over Liquid Glass's rows.
private struct PaletteControlSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.paletteTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch theme {
        case .smallcast: content.frosted(in: shape)
        // Rows dissolve beneath the footer, so its controls must blur them or a label reads through.
        case .liquidGlass: content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    func paletteControlSurface(in shape: some Shape) -> some View {
        modifier(PaletteControlSurface(shape: shape))
    }
}
