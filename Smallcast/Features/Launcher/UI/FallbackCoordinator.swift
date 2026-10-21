import Foundation

/// Owns the launcher's fallback section: what it offers for a query, and where running one goes.
@MainActor
final class FallbackCoordinator {
    private let store: FallbackStore
    private let quicklinks: QuicklinkStore
    private let prompts: QuickPromptStore
    private let settings: AppSettings
    private let visibility: VisibilityStore
    /// The five destinations a fallback hands its query to; nothing here is this type's own state.
    private unowned let core: AppCore

    init(
        store: FallbackStore, quicklinks: QuicklinkStore, prompts: QuickPromptStore,
        settings: AppSettings, visibility: VisibilityStore, core: AppCore
    ) {
        self.store = store
        self.quicklinks = quicklinks
        self.prompts = prompts
        self.settings = settings
        self.visibility = visibility
        self.core = core
    }

    /// Everything this Mac can offer today, in the reader's order — Settings lists exactly this.
    var available: [Fallback] { store.ordered(candidates) }

    /// The launcher's rows. An empty query is nobody's input, so it earns no section at all.
    func entries(for query: String) -> [(fallback: Fallback, entry: AppEntry)] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return available.filter(store.isEnabled).compactMap { fallback in
            entry(for: fallback).map { (fallback, $0) }
        }
    }

    /// Nil for a quicklink, prompt or preset deleted since the order was stored.
    func entry(for fallback: Fallback) -> AppEntry? {
        switch fallback {
        case .builtin(let builtin): return CommandCatalog.makeEntry(builtin.command)
        case .quicklink(let id): return quicklinks.quicklink(id: id).map(AppEntry.init)
        case .quickPrompt(let id): return prompts.prompt(id: id).map(AppEntry.init)
        case .preset(let id):
            guard let preset = store.preset(id: id), let target = entry(for: preset.target)
            else { return nil }
            // Its own id and name over the target's glyph; the subtitle says what it runs.
            var entry = AppEntry(
                id: preset.entryID, name: preset.name, url: target.url, bundleID: nil,
                kind: target.kind, subtitle: target.name, symbolName: target.symbolName)
            entry.buildSearchProfile()
            return entry
        }
    }

    func entry(for target: FallbackPreset.Target) -> AppEntry? {
        entry(for: Self.fallback(for: target))
    }

    /// The arguments a preset may give, in the order the target declares them.
    func arguments(of target: FallbackPreset.Target) -> [SnippetTemplateEngine.DeclaredArgument] {
        switch target {
        case .quicklink(let id): quicklinks.quicklink(id: id).map {
                SnippetTemplateEngine.declaredArguments(in: $0.link)
            } ?? []
        case .quickPrompt(let id): prompts.prompt(id: id)?.arguments ?? []
        }
    }

    /// Everything a preset can stand on: the quicklinks and prompts offered as fallbacks today.
    var presetTargets: [FallbackPreset.Target] {
        targetCandidates.compactMap { fallback in
            switch fallback {
            case .quicklink(let id): .quicklink(id)
            case .quickPrompt(let id): .quickPrompt(id)
            case .builtin, .preset: nil
            }
        }
    }

    /// The footer pill's verb; a preset speaks in its target's words.
    func openVerb(for fallback: Fallback) -> String {
        guard case .preset(let id) = fallback, let preset = store.preset(id: id) else {
            return fallback.openVerb
        }
        return Self.fallback(for: preset.target).openVerb
    }
    func run(_ fallback: Fallback, query: String) {
        switch fallback {
        case .builtin(.quickAI): core.quickAICoordinator.ask(query)
        case .builtin(.searchFiles): core.fileSearchCoordinator.show(query: query)
        case .builtin(.runShellCommand): core.customCommandCoordinator.runShellCommand(query)
        case .builtin(.define): core.dictionaryCoordinator.show(term: query)
        case .quicklink(let id): core.quicklinkCoordinator.openQuicklink(id: id, filling: query)
        case .quickPrompt(let id): core.quickPromptCoordinator.run(id: id, filling: query)
        case .preset(let id):
            guard let preset = store.preset(id: id) else { return }
            let values = FallbackPreset.values(
                filling: query, into: arguments(of: preset.target), given: preset.values)
            switch preset.target {
            case .quicklink(let id): core.quicklinkCoordinator.openQuicklink(id: id, values: values)
            case .quickPrompt(let id): core.quickPromptCoordinator.run(id: id, values: values)
            }
        }
    }

    func savePreset(_ preset: FallbackPreset) {
        store.save(preset)
    }

    func deletePreset(id: UUID) {
        store.removePresets { $0.id == id }
    }

    /// A deleted quicklink or prompt takes the presets built on it, so none outlives its target.
    func prunePresets() {
        store.removePresets { preset in
            switch preset.target {
            case .quicklink(let id): quicklinks.quicklink(id: id) == nil
            case .quickPrompt(let id): prompts.prompt(id: id) == nil
            }
        }
    }

    private static func fallback(for target: FallbackPreset.Target) -> Fallback {
        switch target {
        case .quicklink(let id): .quicklink(id)
        case .quickPrompt(let id): .quickPrompt(id)
        }
    }

    /// The section's gear and the row's own action; the palette closes behind the pane.
    func showSettings() {
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        core.settingsCoordinator.showSettings(tab: .fallbacks)
    }

    /// A fallback whose feature is switched off is offered nowhere, Settings included.
    private var candidates: [Fallback] {
        let targets = targetCandidates
        let presets = store.presets
            .filter { targets.contains(Self.fallback(for: $0.target)) }
            .map { Fallback.preset($0.id) }
        return Fallback.Builtin.allCases.filter(isAvailable).map(Fallback.builtin) + targets + presets
    }

    /// The quicklinks and prompts that declare an argument, which is what makes them a fallback.
    private var targetCandidates: [Fallback] {
        var result: [Fallback] = []
        if settings.quicklinksEnabled {
            result += quicklinks.quicklinks
                .filter { $0.isEnabled && QuicklinkDestination.containsPlaceholder($0.link) }
                .sorted(by: Quicklink.precedes)
                .map { .quicklink($0.id) }
        }
        if settings.aiEnabled {
            result += prompts.prompts.filter { $0.isEnabled && !$0.arguments.isEmpty }
                .map { .quickPrompt($0.id) }
        }
        return result
    }

    private func isAvailable(_ builtin: Fallback.Builtin) -> Bool {
        switch builtin {
        case .quickAI: return settings.aiEnabled
        case .searchFiles: return settings.fileSearchEnabled
        // Its own capability: this shell is not the custom-command library's switch to hold.
        case .runShellCommand: return true
        // Settings › Commands is Define's only switch, so hiding the command there hides this too.
        case .define: return visibility.isVisible(CommandCatalog.makeEntry(.define))
        }
    }
}
