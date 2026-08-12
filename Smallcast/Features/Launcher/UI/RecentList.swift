import SwiftUI

/// The Recent list, under the same day headers the clipboard and calculator histories use. Rows are
/// the launcher's and the calculator history's own, so a remembered command looks exactly as it does
/// where it came from.
struct RecentList: View {
    let results: [HistoryItem]
    let selectedID: HistoryItem.ID?
    /// Changes only when the list should scroll, so mouse selection never yanks it.
    let scroll: ScrollIntent
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
                            RecentRow(item: item, selected: item.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(item)
                                    onActivate()
                                }
                                .onRightClick { onActions(item) }
                                .selectionFrame(item.id == selectedID)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID, atOrigin: selectedID == results.first?.id, proxy: proxy)
        }
    }
}

private struct RecentRow: View {
    let item: HistoryItem
    let selected: Bool
    /// The same running dot the launcher draws, so a remembered app reads identically in both.
    @Environment(RunningAppsMonitor.self) private var runningApps

    var body: some View {
        switch item {
        case .entry(let app, _):
            AppRow(app: app, selected: selected, running: runningApps.isRunning(app))
        case .calculation(let entry):
            CalcHistoryRow(entry: entry, selected: selected)
        }
    }
}
