import SwiftUI

/// One grid row of tiles; `start` is its first tile's flat selection index.
private struct AppGridRow: Identifiable {
    let id: String
    let start: Int
    let apps: ArraySlice<AppEntry>
    let isLastInSection: Bool

    subscript(column: Int) -> AppEntry {
        apps[apps.index(apps.startIndex, offsetBy: column)]
    }
}

/// Headers and rows in visible order; the rows are the scroll targets.
private enum AppGridItem: Identifiable {
    case header(id: String, title: String)
    case row(AppGridRow)

    var id: String {
        switch self {
        case .header(let id, _): id
        case .row(let row): row.id
        }
    }
}

/// The Applications grid: Spotlight's chips over a scrolling grid of app tiles.
struct AppGridView: View {
    let sections: [AppGridSection]
    let categories: [AppCategory]
    let selection: Int
    let columns: Int
    let scroll: ScrollIntent
    let filter: AppCategory?
    let onFilter: (AppCategory?) -> Void
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void
    let onActions: (Int) -> Void
    @Environment(\.metrics) private var metrics

    private var items: [AppGridItem] {
        var items: [AppGridItem] = []
        for section in sections {
            items.append(.header(id: section.id + "-header", title: section.title))
            var offset = 0
            var row = 0
            while offset < section.apps.count {
                let end = min(offset + columns, section.apps.count)
                items.append(
                    .row(
                        AppGridRow(
                            id: section.id + "-row-\(row)", start: section.start + offset,
                            apps: section.apps[offset..<end],
                            isLastInSection: end == section.apps.count)))
                offset = end
                row += 1
            }
        }
        return items
    }

    /// The row holding the selection; section-namespaced, since a frequent app is listed twice.
    private var selectedRowID: String? {
        guard let section = sections.last(where: { selection >= $0.start }),
            selection - section.start < section.apps.count
        else { return nil }
        return section.id + "-row-\((selection - section.start) / columns)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if categories.count > 1 {
                AppCategoryChips(categories: categories, filter: filter, onFilter: onFilter)
            }
            if sections.isEmpty {
                EmptyResults(text: "No applications found")
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        let items = items
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .header(_, let title):
                            SectionHeader(title: title, isFirst: item.id == items.first?.id)
                                .padding(.horizontal, metrics.spacing.md)
                        case .row(let row):
                            AppGridRowView(
                                row: row, selection: selection, columns: columns,
                                onSelect: onSelect, onActivate: onActivate, onActions: onActions
                            )
                            .padding(.bottom, row.isLastInSection ? 0 : metrics.spacing.xs)
                            .selectionFrame(item.id == selectedRowID)
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            // The chips sit between the field and the grid, so no bar overlaps the grid's top edge.
            .overflowFade(includingTop: true)
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedRowID,
                atOrigin: selectedRowID == sections.first.map { $0.id + "-row-0" }, proxy: proxy)
        }
    }
}

/// Spotlight's category chips: one filter at a time, and choosing the lit one clears it.
private struct AppCategoryChips: View {
    let categories: [AppCategory]
    let filter: AppCategory?
    let onFilter: (AppCategory?) -> Void
    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: metrics.spacing.sm) {
                ForEach(categories) { category in
                    let selected = filter == category
                    Button {
                        onFilter(selected ? nil : category)
                    } label: {
                        Text(category.title)
                            .font(metrics.typography.rowTrailing)
                            .foregroundStyle(
                                selected ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, metrics.spacing.lg)
                            .frame(height: metrics.size.appGridChipHeight)
                            .background(
                                Capsule().fill(
                                    selected ? Theme.Colors.selection : Theme.Colors.controlSurface))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, metrics.spacing.md * 2)
        }
        .scrollIndicators(.never)
        .padding(.vertical, metrics.spacing.md)
    }
}

/// One grid row, owning all interaction for its tiles, as the emoji grid's rows do.
private struct AppGridRowView: View {
    let row: AppGridRow
    let selection: Int
    let columns: Int
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void
    let onActions: (Int) -> Void
    @Environment(\.metrics) private var metrics
    @Environment(PaletteState.self) private var palette
    @State private var hoveredColumn: Int?

    private var spacing: CGFloat { metrics.spacing.xs }

    /// The palette's width is a metric, so tiles size without a measuring pass.
    private var tileWidth: CGFloat {
        let count = CGFloat(columns)
        let content = metrics.size.panelWidth - metrics.spacing.md * 2
        return (content - spacing * (count - 1)) / count
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<columns, id: \.self) { column in
                if column < row.apps.count {
                    AppTile(
                        app: row[column], selected: row.start + column == selection,
                        hovered: column == hoveredColumn, width: tileWidth)
                } else {
                    // A partial last row keeps its tiles on the full rows' columns.
                    Color.clear.frame(width: tileWidth, height: metrics.size.appGridCellHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // One click opens, as a launcher row and Spotlight's own tile both do.
        .gesture(
            SpatialTapGesture().onEnded { value in
                guard let column = column(at: value.location) else { return }
                onSelect(row.start + column)
                onActivate(row.start + column)
            }
        )
        .onRightClick { point in
            if let column = column(at: point) { onActions(row.start + column) }
        }
        // Gated on real pointer movement, like `armedHover`.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                hoveredColumn = palette.hoverHighlightArmed ? column(at: point) : nil
            case .ended:
                hoveredColumn = nil
            }
        }
        .onChange(of: palette.hoverDisarmToken) { hoveredColumn = nil }
    }

    /// Point → column, rejecting the gap between tiles and the empty slots of a partial row.
    private func column(at point: CGPoint) -> Int? {
        guard point.x >= 0 else { return nil }
        let pitch = tileWidth + spacing
        let column = Int(point.x / pitch)
        guard column < row.apps.count, point.x - CGFloat(column) * pitch <= tileWidth else {
            return nil
        }
        return column
    }
}

/// Pure content: an app's icon over its one-line name, lit by selection, then hover.
private struct AppTile: View {
    let app: AppEntry
    let selected: Bool
    let hovered: Bool
    let width: CGFloat
    @Environment(\.metrics) private var metrics

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        return hovered ? Theme.Colors.rowHover : Color.clear
    }

    var body: some View {
        VStack(spacing: metrics.spacing.xs) {
            EntryIconView(source: .file(stamp: app.iconStamp), fileURL: app.url)
                .frame(width: metrics.size.appGridIcon, height: metrics.size.appGridIcon)
            Text(app.name)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, metrics.spacing.xs)
        }
        .frame(width: width, height: metrics.size.appGridCellHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
