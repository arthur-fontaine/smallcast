import SwiftUI

/// What you just did: launches and calculations interleaved, newest first. Reached with ↑ on an
/// empty search, which is the gesture a shell prompt already trained everyone to expect.
struct RecentScreen: PaletteScreen {
    let launchHistory: LaunchHistoryStore
    let appIndex: AppIndex
    let calcHistory: CalculatorHistoryStore
    let favorites: FavoritesStore
    let runningApps: RunningAppsMonitor
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [HistoryItem] {
        HistoryFeed.build(
            launches: launchHistory.records, apps: appIndex.apps,
            calculations: calcHistory.entries, query: vm.query)
    }

    var primaryActionTitle: String {
        switch item(at: vm.selection) {
        case .entry(let app, _): return app.kind.descriptor.openVerb
        case .calculation: return "Copy Answer"
        case nil: return "Open"
        }
    }

    private func item(at selection: Int) -> HistoryItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let item = item(at: selection) else { return nil }
        return RecentActionsMenu.content(
            item: item, core: core, favorites: favorites,
            running: isRunning(item), launchHistory: launchHistory, calcHistory: calcHistory)
    }

    func activate(at selection: Int) {
        switch item(at: selection) {
        case .entry(let app, _): core.launcherCoordinator.launch(app)
        case .calculation(let entry): core.calculatorCoordinator.copyHistoryEntry(entry)
        case nil: break
        }
    }

    func secondary(at selection: Int) -> Bool { false }

    private func isRunning(_ item: HistoryItem) -> Bool {
        guard case .entry(let app, _) = item else { return false }
        return runningApps.isRunning(app)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        let rows = rows
        guard !rows.isEmpty else {
            return AnyView(
                EmptyResults(
                    text: vm.query.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Nothing here yet" : "No matching history"))
        }
        return AnyView(
            RecentList(
                results: rows,
                selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                scroll: scroll,
                onSelect: { item in
                    if let index = rows.firstIndex(of: item) { vm.selection = index }
                },
                onActivate: { activate(at: selection) },
                onActions: { item in
                    if let index = rows.firstIndex(of: item) { vm.selection = index }
                    openActions()
                }))
    }
}

/// Actions for a Recent row — the underlying item's own menu, plus forgetting it.
@MainActor
enum RecentActionsMenu {
    static func content(
        item: HistoryItem, core: AppCore, favorites: FavoritesStore, running: Bool,
        launchHistory: LaunchHistoryStore, calcHistory: CalculatorHistoryStore
    ) -> PopoverMenuContent {
        switch item {
        case .entry(let app, _):
            let content = AppActionsMenu.content(
                app: app, searchQuery: "", core: core, favorites: favorites, running: running,
                onResetRanking: { core.launcherRanking.reset(itemKey: app.preferenceKey) })
            let forget = PopoverMenuItem(
                title: "Remove from History", systemImage: "trash", isDestructive: true
            ) { launchHistory.reset(itemKey: app.preferenceKey) }
            return PopoverMenuContent(
                header: content.header,
                items: content.items + [
                    forget, clearAll(launchHistory: launchHistory, calcHistory: calcHistory)
                ])
        case .calculation(let entry):
            let content = CalcHistoryActionsMenu.content(
                entry: entry, core: core, calcHistory: calcHistory)
            // The calculator's own menu already deletes this entry; only "everything" is new here.
            let items = content.items.filter { $0.title != "Delete All Entries" }
            return PopoverMenuContent(
                header: content.header,
                items: items + [clearAll(launchHistory: launchHistory, calcHistory: calcHistory)])
        }
    }

    private static func clearAll(
        launchHistory: LaunchHistoryStore, calcHistory: CalculatorHistoryStore
    ) -> PopoverMenuItem {
        PopoverMenuItem(title: "Clear History", systemImage: "trash.fill", isDestructive: true) {
            launchHistory.reset(since: nil)
            calcHistory.clearAll()
        }
    }
}
