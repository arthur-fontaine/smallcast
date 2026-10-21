import SwiftUI

/// What you just did: launches, files and calculations, newest first. Reached with ↑ on an
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
            calculations: calcHistory.entries, query: vm.query,
            sensitivity: core.settings.rootSearchSensitivity,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    var primaryActionTitle: String {
        switch item(at: vm.selection) {
        case .entry(let app, _): return String(localized: app.kind.descriptor.openVerb)
        case .file(let result, _):
            return result.isDirectory ? String(localized: "Open Folder") : String(localized: "Open File")
        case .calculation: return String(localized: "Copy Answer")
        case nil: return String(localized: "Open")
        }
    }

    private func item(at selection: Int) -> HistoryItem? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    private func file(at selection: Int) -> FileSearchResult? {
        guard case .file(let result, _) = item(at: selection) else { return nil }
        return result
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
        case .file(let result, _): core.fileSearchCoordinator.open(result)
        case .calculation(let entry): core.calculatorCoordinator.copyHistoryEntry(entry)
        case nil: break
        }
    }

    func secondary(at selection: Int) -> Bool {
        guard let file = file(at: selection) else { return false }
        core.fileSearchCoordinator.showInFinder(file)
        return true
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        guard let file = file(at: selection) else { return false }
        return FileSearchActionsMenu.perform(shortcut, result: file, core: core)
    }

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
                }
            )
            .filePreviewOverlay(selected: file(at: selection), vm: vm))
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
            // Reordering needs the visible favorites order, which this screen does not have.
            let content = AppActionsMenu.content(
                app: app, searchQuery: "", core: core, running: running,
                favorites: AppActionsMenu.FavoriteActions(
                    isFavorite: favorites.isFavorite(app),
                    canMoveUp: false,
                    canMoveDown: false,
                    toggle: { favorites.toggle(app) },
                    move: { _ in }),
                onResetRanking: { core.launcherRanking.reset(itemKey: app.preferenceKey) },
                onHideFromSearch: { core.visibility.setItemVisible(false, for: app) })
            let forget = PopoverMenuItem(
                title: "Remove from History", systemImage: "trash", isDestructive: true
            ) { launchHistory.reset(itemKey: app.preferenceKey) }
            return PopoverMenuContent(
                header: content.header,
                items: content.items + [
                    forget, clearAll(launchHistory: launchHistory, calcHistory: calcHistory)
                ])
        case .file(let result, _):
            let content = FileSearchActionsMenu.content(result: result, core: core, target: core.palette.pasteTarget)
            let forget = PopoverMenuItem(
                title: "Remove from History", systemImage: "trash", isDestructive: true
            ) { launchHistory.reset(itemKey: result.historyKey) }
            // Trash is the File Search screen's to offer; here the row is a memory, not the file.
            let items = content.items.filter { !$0.isDestructive }
            return PopoverMenuContent(
                header: content.header,
                items: items + [forget, clearAll(launchHistory: launchHistory, calcHistory: calcHistory)])
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
