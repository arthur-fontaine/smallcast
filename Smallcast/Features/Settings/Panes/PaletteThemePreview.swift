import SwiftUI

/// A miniature palette in one theme, drawn with the palette's own tokens.
struct PaletteThemePreview: View {
    let theme: PaletteTheme

    private static let inset = CGSize(width: 14, height: 11)
    private static let searchRow: CGFloat = 14
    private static let row: CGFloat = 9
    private static let footer: CGFloat = 12
    private static let glyph: CGFloat = 6
    private static let textLine: CGFloat = 2.5
    private static let titles: [CGFloat] = [42, 30, 50]
    private static let icons: [Color] = [.blue, .orange, .green]

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous)
        return desk
            .overlay { palette.padding(.horizontal, Self.inset.width).padding(.vertical, Self.inset.height) }
            .frame(width: Theme.Size.settingsModePreview.width, height: Theme.Size.settingsModePreview.height)
            .clipShape(tile)
            .accessibilityHidden(true)
    }

    private var desk: some View {
        LinearGradient(
            colors: Theme.Colors.themePreviewDesk, startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Theme.Colors.themePreviewDeskShade)
                .frame(width: 70, height: 70)
                .blur(radius: 14)
                .offset(x: -12, y: 22)
        }
    }

    @ViewBuilder
    private var palette: some View {
        switch theme {
        case .smallcast:
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            content
                .background(Theme.Colors.panelScrim)
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        case .liquidGlass:
            // The capsule's radius, as the real card keeps it: its ends become the card's corners.
            let shape = RoundedRectangle(cornerRadius: Self.searchRow / 2 + 2, style: .continuous)
            content
                .background(Theme.Colors.glassScrim)
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: theme == .liquidGlass ? 6.5 : 5.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                Capsule()
                    .fill(Theme.Colors.textTertiary)
                    .frame(width: 34, height: Self.textLine)
            }
            .frame(height: Self.searchRow)
            .padding(.horizontal, 6)
            if theme == .liquidGlass {
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(height: 0.5)
                    .padding(.horizontal, 6)
            }
            VStack(spacing: 0) {
                ForEach(Self.titles.indices, id: \.self) { index in
                    row(index)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
            Spacer(minLength: 0)
            footer
        }
    }

    private func row(_ index: Int) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Self.icons[index])
                .frame(width: Self.glyph, height: Self.glyph)
            Capsule()
                .fill(Theme.Colors.textSecondary)
                .frame(width: Self.titles[index], height: Self.textLine)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: Self.row)
        .background {
            if index == 0 {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Theme.Colors.selection)
            }
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(Theme.Colors.controlSurface)
                .frame(width: 8, height: 8)
            Spacer()
            Capsule()
                .fill(Theme.Colors.controlSurface)
                .frame(width: 34, height: 8)
        }
        .padding(.horizontal, 3)
        .frame(height: Self.footer)
    }
}
