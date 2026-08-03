import SwiftUI

/// The "make it look native" control in Settings › Extensions: shows what an extension currently draws
/// in the launcher, and opens a picker to replace it with a curated SF Symbol on a tinted tile.
struct ExtensionAppearanceRow: View {
    let installed: InstalledExtension
    @ObservedObject private var extensions = AppCore.shared.extensions
    /// Observed directly: picking publishes from the store, not from the manager, so the preview and
    /// the open popover both need to be watching *it*.
    @ObservedObject private var appearances = AppCore.shared.extensions.appearances
    @State private var picking = false

    private var appearance: ExtensionAppearance? {
        appearances.appearance(for: installed.manifest.name)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            preview
            VStack(alignment: .leading, spacing: Theme.Spacing.xs / 2) {
                Text("Launcher icon").font(.body)
                Text(
                    appearance == nil
                        ? "Using the icon this extension ships."
                        : "Replaced with a Smallcast icon."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.xl)
            if appearance != nil {
                Button("Use Original") {
                    extensions.setAppearance(nil, for: installed.manifest.name)
                }
            }
            Button("Choose…") { picking = true }
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    ExtensionAppearancePicker(
                        current: appearance ?? .fallback,
                        onPick: { extensions.setAppearance($0, for: installed.manifest.name) })
                }
        }
    }

    /// Exactly what the launcher row will draw — the shipped image, or the chosen tile.
    @ViewBuilder
    private var preview: some View {
        if let appearance {
            SymbolTile(symbol: appearance.symbol, tint: appearance.tint, side: 26)
        } else {
            ExtensionIconView(
                resolved: installed.iconPath.map { ExtensionImage.Resolved(source: .file($0)) },
                size: 26)
        }
    }
}

/// Symbol grid + colour row. Every change applies immediately — the launcher is the real preview, and
/// an OK/Cancel dance over two properties isn't worth it.
private struct ExtensionAppearancePicker: View {
    let current: ExtensionAppearance
    let onPick: (ExtensionAppearance) -> Void

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 4), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Colour")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(ExtensionTint.allCases) { tint in
                    Button {
                        onPick(ExtensionAppearance(symbol: current.symbol, tint: tint))
                    } label: {
                        Circle()
                            .fill(tint.color.gradient)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle().strokeBorder(
                                    .white.opacity(tint == current.tint ? 0.9 : 0), lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tint.rawValue.capitalized)
                }
            }

            Text("Icon")
                .font(Theme.Typography.sectionHeader)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(ExtensionSymbols.all, id: \.self) { symbol in
                        Button {
                            onPick(ExtensionAppearance(symbol: symbol, tint: current.tint))
                        } label: {
                            SymbolTile(symbol: symbol, tint: current.tint, side: 30)
                                .opacity(symbol == current.symbol ? 1 : 0.55)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            .white.opacity(symbol == current.symbol ? 0.9 : 0),
                                            lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: 360, height: 220)
        }
        .padding(Theme.Spacing.xl)
    }
}

/// The launcher's icon tile, drawn in SwiftUI so the picker previews exactly what `IconCache` renders.
private struct SymbolTile: View {
    let symbol: String
    let tint: ExtensionTint
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
            .fill(tint.color)
            .frame(width: side, height: side)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: side * 0.46, weight: .medium))
                    .foregroundStyle(.white)
            )
    }
}
