import SwiftUI

/// DigUp's rows below root search's fallbacks: a few files, then Show More when DigUp found more.
struct DigUpRootSection: Equatable {
    let results: [FileSearchResult]
    let hasMore: Bool

    /// Rows this section adds to the flat selection index, Show More included.
    var rowCount: Int { results.count + (hasMore ? 1 : 0) }

    /// Nil when DigUp has nothing to show; its rows only ever arrive after the static ones.
    @MainActor
    static func make(query: String, core: AppCore) -> DigUpRootSection? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
            core.fallbackCoordinator.digUpReplacesSearchFiles
        else { return nil }
        let found = core.digUpPreview.results
        guard !found.isEmpty else { return nil }
        let limit = DigUpSearchPolicy.rootRowLimit
        return DigUpRootSection(results: Array(found.prefix(limit)), hasMore: found.count > limit)
    }

    /// File Search's menu minus Quick Look and Trash, which only its own screen carries out.
    @MainActor
    static func actions(for result: FileSearchResult, core: AppCore) -> PopoverMenuContent {
        let coordinator = core.fileSearchCoordinator
        return PopoverMenuContent(
            header: result.name,
            items: [
                PopoverMenuItem(
                    title: result.isDirectory ? "Open Folder" : "Open File",
                    systemImage: result.isDirectory ? "folder" : "doc", shortcut: "↵"
                ) { coordinator.open(result) },
                PopoverMenuItem(
                    title: "Show in Finder", systemImage: "folder", shortcut: "⌘↵"
                ) { coordinator.showInFinder(result) },
                PopoverMenuItem(
                    title: "Copy File", systemImage: "doc.on.clipboard", startsSection: true,
                    shortcut: "⇧⌘C"
                ) { coordinator.copyFile(result) },
                PopoverMenuItem(
                    title: "Copy Name", systemImage: "doc.on.clipboard", shortcut: "⌥⌘C"
                ) { coordinator.copyName(result) },
                PopoverMenuItem(
                    title: "Copy Path", systemImage: "doc.on.clipboard", shortcut: "⌃⌘C"
                ) { coordinator.copyPath(result) }
            ])
    }

    /// The menu's chords, answered on a file row before the launcher reads them as its own.
    @MainActor
    static func perform(_ shortcut: PaletteShortcut, on result: FileSearchResult, core: AppCore) -> Bool {
        let coordinator = core.fileSearchCoordinator
        switch shortcut {
        case .copyFile: coordinator.copyFile(result)
        case .copyName: coordinator.copyName(result)
        case .copyPath: coordinator.copyPath(result)
        default: return false
        }
        return true
    }
}

/// What `LauncherList` needs to draw the section, addressed by position like its fallbacks.
struct DigUpListSection {
    let section: DigUpRootSection
    let onActivate: (Int) -> Void
    let onActions: (Int) -> Void
    let onShowMore: () -> Void
    let onDropped: () -> Void
}

/// Asks DigUp as the query changes; leaving root search drops the answer with the rows.
struct DigUpRootSearch: ViewModifier {
    let query: String
    let core: AppCore

    private struct Request: Equatable {
        let query: String
        let runner: DigUpSearchRunner?
    }

    func body(content: Content) -> some View {
        let runner = core.digUpState.runner(
            limit: DigUpSearchPolicy.rootRowLimit + 1,
            enabled: core.fallbackCoordinator.digUpReplacesSearchFiles)
        return content
            .task(id: Request(query: query, runner: runner)) {
                let preview = core.digUpPreview
                preview.digUp = runner
                if runner == nil { preview.cancel() } else { preview.search(query) }
            }
            .onDisappear { core.digUpPreview.cancel() }
    }
}

struct DigUpShowMoreRow: View {
    @Environment(\.metrics) private var metrics
    let selected: Bool
    @State private var hovered = false
    /// The tile the command rows draw, so this row's icon sits among theirs as one of them.
    @State private var icon = IconCache.cachedSymbol(named: Self.symbol)
    private static let symbol = "ellipsis"

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                        .fill(Theme.Colors.iconPlaceholder)
                }
            }
            .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            Text("Show More Results")
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("DigUp")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill)
        )
        .armedHover($hovered)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task {
            if icon == nil { icon = await IconCache.loadSymbolAsync(named: Self.symbol) }
        }
    }
}
