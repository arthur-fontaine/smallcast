import SwiftUI

/// One titled run of grid tiles; `start` is the flat selection index of its first tile.
struct AppGridSection: Identifiable {
    let title: String
    let apps: [AppEntry]
    let start: Int

    var id: String { title }
}

/// Every installed app as a grid, as Spotlight's Applications view: frequent first, then A to Z.
struct AppGridScreen: PaletteScreen {
    let appIndex: AppIndex
    let launchHistory: LaunchHistoryStore
    let favorites: FavoritesStore
    let visibility: VisibilityStore
    let runningApps: RunningAppsMonitor
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    private var columns: Int { Theme.Size.appGridColumns }

    /// What the search can show: applications only, and none the user hid from it.
    private var apps: [AppEntry] {
        appIndex.apps.filter { $0.kind == .application && visibility.isVisible($0) }
    }

    /// The chips worth offering: a category no installed app falls in would filter to nothing.
    var categories: [AppCategory] {
        let present = Set(apps.map { $0.appCategory ?? .other })
        return AppCategory.allCases.filter(present.contains)
    }

    var sections: [AppGridSection] {
        var sections: [AppGridSection] = []
        var start = 0
        func append(_ title: String, _ apps: [AppEntry]) {
            guard !apps.isEmpty else { return }
            sections.append(AppGridSection(title: title, apps: apps, start: start))
            start += apps.count
        }
        let inCategory = apps.filter { app in
            vm.appCategoryFilter.map { (app.appCategory ?? .other) == $0 } ?? true
        }
        let query = vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let ranked = inCategory.compactMap { app in
                FuzzyMatch.score(query: query, candidate: app.name).map { (app, $0) }
            }
            append("Results", ranked.sorted { $0.1 > $1.1 }.map(\.0))
        } else if let category = vm.appCategoryFilter {
            append(category.title, inCategory)
        } else {
            append("Frequently Used", frequent(in: inCategory))
            append("Applications", inCategory)
        }
        return sections
    }

    /// One row of the most launched, so the grid opens on what is wanted most often.
    private func frequent(in apps: [AppEntry]) -> [AppEntry] {
        let used = apps.filter { launchHistory.count(itemKey: $0.preferenceKey) > 0 }
        let ranked = used.sorted { lhs, rhs in
            let left = launchHistory.count(itemKey: lhs.preferenceKey)
            let right = launchHistory.count(itemKey: rhs.preferenceKey)
            if left != right { return left > right }
            return (launchHistory.lastUsed(itemKey: lhs.preferenceKey) ?? .distantPast)
                > (launchHistory.lastUsed(itemKey: rhs.preferenceKey) ?? .distantPast)
        }
        return Array(ranked.prefix(columns))
    }

    var rows: [AppEntry] { sections.flatMap(\.apps) }

    var primaryActionTitle: String { String(localized: AppEntry.Kind.application.descriptor.openVerb) }

    private func app(at selection: Int) -> AppEntry? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let app = app(at: selection) else { return nil }
        // Reordering needs the favorites list's own order, which a grid does not show.
        return AppActionsMenu.content(
            app: app, searchQuery: vm.query, core: core, running: runningApps.isRunning(app),
            favorites: AppActionsMenu.FavoriteActions(
                isFavorite: favorites.isFavorite(app), canMoveUp: false, canMoveDown: false,
                toggle: { favorites.toggle(app) }, move: { _ in }),
            onResetRanking: { core.launcherRanking.reset(itemKey: app.preferenceKey) },
            onHideFromSearch: { core.visibility.setItemVisible(false, for: app) })
    }

    func activate(at selection: Int) {
        guard let app = app(at: selection) else { return }
        core.launcherCoordinator.launch(app)
    }

    /// ⌘↵ reveals the app, as the launcher's own row does.
    func secondary(at selection: Int) -> Bool {
        guard let app = app(at: selection) else { return false }
        core.launcherCoordinator.showInFinder(app)
        return true
    }

    /// ⇥ walks the chips as Spotlight's own Tab does; past the last one is every app again.
    func tab(at selection: Int, backwards: Bool) -> Bool {
        let chips: [AppCategory?] = [nil] + categories.map(Optional.some)
        let current = chips.firstIndex(of: vm.appCategoryFilter) ?? 0
        let next = (current + (backwards ? chips.count - 1 : 1)) % chips.count
        vm.appCategoryFilter = chips[next]
        return true
    }

    /// One visual row vertically, keeping the column across sections; one tile horizontally.
    func move(_ delta: Int, axis: PaletteAxis, from selection: Int) -> Int? {
        let sections = sections
        let count = sections.reduce(0) { $0 + $1.apps.count }
        guard count > 0 else { return selection }
        switch axis {
        case .vertical:
            let geometry = EmojiGridGeometry(counts: sections.map(\.apps.count), columns: columns)
            return delta > 0 ? geometry.down(from: selection) : geometry.up(from: selection)
        case .horizontal:
            return min(max(selection + delta, 0), count - 1)
        }
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        let sections = sections
        return AnyView(
            AppGridView(
                sections: sections, categories: categories, selection: selection,
                columns: columns, scroll: scroll,
                filter: vm.appCategoryFilter,
                onFilter: { vm.appCategoryFilter = $0 },
                onSelect: { vm.selection = $0 },
                onActivate: { activate(at: $0) },
                onActions: { flat in
                    vm.selection = flat
                    openActions()
                }))
    }
}
