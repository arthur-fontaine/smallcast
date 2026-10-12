import SwiftUI

/// The palette's backdrop, corner and arrival, per theme; nothing drawn above it branches on theme.
struct PaletteSurface: ViewModifier {
    let isDimmed: Bool
    let presentation: PalettePresentation
    @Environment(\.paletteTheme) private var theme
    @Environment(\.metrics) private var metrics

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
            dimmable(
                content
                    .background(Theme.Colors.glassScrim)
                    .glassEffect(.regular, in: shape)
            )
            .clipShape(shape)
            .scaleEffect(x: presentationScale, y: 1)
        }
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
