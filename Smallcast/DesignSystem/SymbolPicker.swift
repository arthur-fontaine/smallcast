import SwiftUI

/// A searchable grid over `SymbolCatalog`, opening on the caller's suggestions, with Automatic.
struct SymbolPicker: View {
    @Binding var selection: String?
    /// Drawn on the Automatic row, and what the row falls back to when nothing is picked.
    let fallback: String
    let suggested: [String]
    let onPick: () -> Void

    /// The curated set until the real catalog lands, so the popover's first frame never waits.
    @State private var catalog = SymbolCatalog.fallback
    @State private var category = SymbolCategory.suggested
    @State private var query = ""

    private static let cell: CGFloat = 30
    private static let cellHeight: CGFloat = 26
    private static let columnCount = 8
    private static let visibleRows: CGFloat = 6.5

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Self.cell), spacing: Theme.Spacing.sm), count: Self.columnCount)
    }

    private static var width: CGFloat {
        let count = CGFloat(columnCount)
        let grid: CGFloat = count * cell + (count - 1) * Theme.Spacing.sm
        return grid + Theme.Spacing.md * 2
    }

    private var results: [String] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return catalog.search(query, in: category)
        }
        return category == .suggested ? suggested : catalog.symbols(in: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $query, prompt: Text("Search symbols…"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                Picker("", selection: $category) {
                    ForEach(catalog.categories) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button {
                selection = nil
                onPick()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    SymbolImage(name: fallback, size: 14)
                    Text("Automatic")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
            let results = results
            if results.isEmpty {
                Text("No symbols match \u{201C}\(query)\u{201D}.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: gridHeight)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(results, id: \.self) { symbol in
                            Button {
                                selection = symbol
                                onPick()
                            } label: {
                                SymbolImage(name: symbol, size: 15, monochrome: true)
                                    .frame(width: Self.cell, height: Self.cellHeight)
                                    .background(
                                        RoundedRectangle(
                                            cornerRadius: Theme.Radius.menu, style: .continuous
                                        )
                                        .fill(selection == symbol ? Theme.Colors.selection : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(symbol)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: gridHeight)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: Self.width)
        .task {
            catalog = await Task.detached(priority: .userInitiated) { SymbolCatalog.system }.value
        }
    }

    private var gridHeight: CGFloat {
        (Self.visibleRows * (Self.cellHeight + Theme.Spacing.sm)).rounded()
    }
}
