import SwiftUI

/// The Recent list: launches and calculations interleaved newest-first, under the same day headers the
/// clipboard and calculator histories use. Rows are the launcher's and the calculator history's own, so
/// a remembered command looks exactly like it does in the launcher.
struct HistoryList: View {
    let results: [HistoryItem]
    let selectedID: HistoryItem.ID?
    /// Changes only when the list should scroll to follow the selection (keyboard nav / reset), so mouse selection never yanks the scroll position.
    let scrollToken: UUID
    let onSelect: (HistoryItem) -> Void
    let onActivate: () -> Void
    let onActions: (HistoryItem) -> Void

    private enum Row: Identifiable {
        case header(String)
        case item(HistoryItem)
        var id: String {
            switch self {
            case .header(let title): return "header-" + title
            case .item(let item): return item.id
            }
        }
    }

    /// Newest-first, so grouping walks and emits a header whenever the day bucket changes.
    private var rows: [Row] {
        var rows: [Row] = []
        var currentBucket: DateBucket?
        for item in results {
            let bucket = DateBucket(for: item.date)
            if bucket != currentBucket {
                rows.append(.header(bucket.title))
                currentBucket = bucket
            }
            rows.append(.item(item))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            SectionHeader(title: title, isFirst: row.id == rows.first?.id)
                        case .item(let item):
                            HistoryRow(item: item, selected: item.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(item)
                                    onActivate()
                                }
                                .onRightClick { onActions(item) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.md)
                .hideNativeScrollers()
            }
            .edgeDissolve()
            .thinScrollbar()
            .onChange(of: scrollToken) {
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let selected: Bool
    /// Same running-app dot the launcher draws, so a remembered app reads identically in both lists.
    @EnvironmentObject private var runningApps: RunningAppsMonitor

    var body: some View {
        switch item {
        case .entry(let app, _):
            AppRow(
                app: app, selected: selected,
                running: app.bundleID.map(runningApps.runningBundleIDs.contains) ?? false)
        case .calculation(let entry):
            CalcHistoryRow(entry: entry, selected: selected)
        }
    }
}

/// Actions menu for a Recent row — the underlying item's own menu, plus removing it from the history.
@MainActor
enum HistoryActionsMenu {
    static func content(
        item: HistoryItem, core: AppCore, favorites: FavoritesStore, usage: UsageStore,
        calcHistory: CalculatorHistoryStore
    ) -> PopoverMenuContent {
        switch item {
        case .entry(let app, _):
            var content = AppActionsMenu.content(app: app, core: core, favorites: favorites)
            content.items.append(
                PopoverMenuItem(title: "Remove from History", systemImage: "trash", isDestructive: true)
                {
                    usage.forget(key: app.usageKey)
                })
            content.items.append(clearAll(usage: usage, calcHistory: calcHistory))
            return content
        case .calculation(let entry):
            var content = CalcHistoryActionsMenu.content(
                entry: entry, core: core, calcHistory: calcHistory)
            // The calculator's own menu already offers deleting this entry; only "everything" is new.
            content.items.removeAll { $0.title == "Delete All Entries" }
            content.items.append(clearAll(usage: usage, calcHistory: calcHistory))
            return content
        }
    }

    private static func clearAll(usage: UsageStore, calcHistory: CalculatorHistoryStore)
        -> PopoverMenuItem
    {
        PopoverMenuItem(title: "Clear History", systemImage: "trash.fill", isDestructive: true) {
            usage.clearAll()
            calcHistory.clearAll()
        }
    }
}
