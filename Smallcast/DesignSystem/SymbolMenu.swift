import Foundation

/// The palette's icon menu: Automatic, the caller's suggestions, then every system symbol.
@MainActor
enum SymbolMenu {
    /// The rows and the one to highlight. A search reaches the whole catalog by its search terms.
    static func content(
        selection: String?, automatic: String, suggested: [String],
        onPick: @escaping (String?) -> Void
    ) -> (content: PopoverMenuContent, selected: Int) {
        let catalog = SymbolCatalog.system
        let suggestedSet = Set(suggested)
        let rest = catalog.symbols.filter { !suggestedSet.contains($0) }
        let items =
            [PopoverMenuItem(title: "Automatic", systemImage: automatic) { onPick(nil) }]
            + suggested.enumerated().map { index, symbol in
                item(symbol, sectionTitle: index == 0 ? "Suggested" : nil, onPick: onPick)
            }
            + rest.enumerated().map { index, symbol in
                item(symbol, sectionTitle: index == 0 ? "All Symbols" : nil, onPick: onPick)
            }
        let selected = selection.flatMap { symbol in
            items.dropFirst().firstIndex { $0.title == symbol }
        } ?? 0
        let content = PopoverMenuContent(items: items) { query in
            catalog.search(query, in: .all).map { item($0, sectionTitle: nil, onPick: onPick) }
        }
        return (content, selected)
    }

    private static func item(
        _ symbol: String, sectionTitle: String?, onPick: @escaping (String?) -> Void
    ) -> PopoverMenuItem {
        PopoverMenuItem(
            title: symbol, icon: SymbolCatalog.isBundled(symbol) ? .asset(symbol) : .symbol(symbol),
            sectionTitle: sectionTitle
        ) { onPick(symbol) }
    }
}
