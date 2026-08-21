import AppKit

/// Runs a fallback row: the typed text becomes the command's input. One funnel, so the row, its
/// Settings entry and the ⌘K row can never disagree about what a fallback does.
@MainActor
final class FallbackCoordinator {
    private let settings: AppSettings
    private let quicklinks: QuicklinkStore
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let fileSearchCoordinator: FileSearchCoordinator
    private let quicklinkCoordinator: QuicklinkCoordinator
    private unowned let core: AppCore

    init(
        settings: AppSettings, quicklinks: QuicklinkStore, palette: PaletteState,
        paletteCoordinator: PaletteCoordinator, fileSearchCoordinator: FileSearchCoordinator,
        quicklinkCoordinator: QuicklinkCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.quicklinks = quicklinks
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.fileSearchCoordinator = fileSearchCoordinator
        self.quicklinkCoordinator = quicklinkCoordinator
        self.core = core
    }

    /// What a no-result search offers, in the user's own order.
    var rows: [FallbackRow] {
        guard settings.fallbackCommandsEnabled else { return [] }
        return FallbackCommands.resolved(
            stored: FallbackCommands.decode(settings.fallbackCommands), availability: availability)
            .map { FallbackRow(command: $0, name: name(of: $0)) }
    }

    /// The stored order as configured, unfiltered — what the Settings list edits.
    var configured: [FallbackCommandID] {
        FallbackCommands.decode(settings.fallbackCommands)
    }

    /// Everything a fallback could be, for the Settings list to add from.
    var candidates: [FallbackCommandID] {
        FallbackCommands.candidates(
            stored: FallbackCommands.decode(settings.fallbackCommands), availability: availability,
            quicklinkIDs: argumentQuicklinks.map(\.id))
    }

    var availability: FallbackCommands.Availability {
        FallbackCommands.Availability(
            aiEnabled: settings.aiEnabled, fileSearchEnabled: settings.fileSearchEnabled,
            argumentQuicklinkIDs: Set(argumentQuicklinks.map(\.id)))
    }

    /// The name a row shows: a built-in's own, or the quicklink's.
    func name(of id: FallbackCommandID) -> String {
        if let name = id.builtInName { return name }
        guard case .quicklink(let quicklink) = id else { return "Fallback" }
        return quicklinks.quicklink(id: quicklink)?.name ?? "Quicklink"
    }

    func run(_ id: FallbackCommandID, query: String) {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        switch id {
        case .askAI:
            core.aiCoordinator.askAI(prompt: text)
        case .searchWeb:
            openWebSearch(text)
        case .searchFiles:
            fileSearchCoordinator.show(query: text)
        case .quicklink(let quicklink):
            quicklinkCoordinator.openQuicklink(id: quicklink, prefilledArgument: text)
        }
    }

    /// Only a quicklink with an `{argument}` has somewhere to put the typed text.
    private var argumentQuicklinks: [Quicklink] {
        guard settings.quicklinksEnabled else { return [] }
        return quicklinks.quicklinks.filter { SnippetTemplateEngine.usesArguments($0.link) }
    }

    private func openWebSearch(_ query: String) {
        guard let url = FallbackCommands.webURL(template: settings.webSearchTemplate, query: query)
        else {
            Task {
                await core.showNotice(
                    title: "Couldn’t Search the Web",
                    message: "The search URL in Settings › Search needs a {query} placeholder.",
                    symbol: "globe", tone: .danger)
            }
            return
        }
        paletteCoordinator.hidePalette(restoreFocus: false)
        NSWorkspace.shared.open(url)
    }
}
