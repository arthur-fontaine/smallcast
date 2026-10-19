import AppKit
import Observation

/// Settings ▸ AI's editor, opened from the launcher, Settings or the Create Quick Prompt command.
struct QuickPromptEditRequest: Identifiable {
    let id = UUID()
    let prompt: QuickPrompt?
}

/// Owns quick prompts: the library, the one run funnel, and a deletion's cleanup.
@MainActor
@Observable
final class QuickPromptCoordinator {
    /// Settings ▸ AI presents the editor for this; set from anywhere that offers editing.
    var editRequest: QuickPromptEditRequest?

    private let store: QuickPromptStore
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let injector: TextInjector
    private let favorites: FavoritesStore
    private let visibility: VisibilityStore
    private let ranking: LauncherRankingStore
    private let aliases: AliasStore
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    /// `{clipboard offset=N}` reads the history a snippet expansion does; one owner, one depth.
    private let clipboardHistory: @MainActor () -> [String]
    /// Quick AI, the fallback list, dialogs and the HUD stay owned by the composition root.
    private unowned let core: AppCore

    init(
        store: QuickPromptStore,
        settings: AppSettings,
        appIndex: AppIndex,
        injector: TextInjector,
        favorites: FavoritesStore,
        visibility: VisibilityStore,
        ranking: LauncherRankingStore,
        aliases: AliasStore,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator,
        clipboardHistory: @escaping @MainActor () -> [String],
        core: AppCore
    ) {
        self.store = store
        self.settings = settings
        self.appIndex = appIndex
        self.injector = injector
        self.favorites = favorites
        self.visibility = visibility
        self.ranking = ranking
        self.aliases = aliases
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.clipboardHistory = clipboardHistory
        self.core = core
    }

    // MARK: - Feature presence

    /// Prompts ride the AI switch: off, they reach the launcher not at all.
    func applyPresence() {
        appIndex.setQuickPrompts(settings.aiEnabled ? store.prompts : [])
        appIndex.setCommandsVisible([.createQuickPrompt], settings.aiEnabled)
    }

    // MARK: - Running

    /// `values` are the header's argument fields; anything still owed sends the row back to them.
    func run(id: UUID, values: [String: String] = [:]) {
        guard let prompt = runnablePrompt(id: id) else { return }
        // With the palette closed a shortcut still reads the selection from wherever the caret is.
        let target =
            windowController.isVisible ? windowController.previousTarget : InjectionTarget.current()
        let context = injector.captureExpansionContext(
            target: target, clipboardHistory: clipboardHistory())
        run(prompt, context: context, copySource: target?.externalApp, values: values)
    }

    /// The fallback row's query, which fills the first `{argument}` the prompt still owes.
    func run(id: UUID, filling query: String) {
        guard let prompt = store.prompt(id: id) else { return }
        run(id: id, values: FallbackPreset.values(filling: query, into: prompt.arguments))
    }

    private func runnablePrompt(id: UUID) -> QuickPrompt? {
        guard settings.aiEnabled, let prompt = store.prompt(id: id), prompt.isEnabled else {
            return nil
        }
        return prompt
    }

    /// Every run ends here, so neither missing values nor an empty selection can be bypassed.
    private func run(
        _ prompt: QuickPrompt, context: SnippetTemplateEngine.ExpansionContext,
        copySource: NSRunningApplication?, values: [String: String]
    ) {
        let expansion = SnippetTemplateEngine.expand(
            text: prompt.template, context: context, userArguments: values)
        guard expansion.missingArguments.isEmpty else {
            paletteCoordinator.showArguments(of: AppEntry(prompt), values: values)
            return
        }
        guard expansion.readsSelection, context.selection.isEmpty else {
            core.quickAICoordinator.ask(expansion.text)
            return
        }
        // An empty `{selection}` fails rather than asking about nothing.
        guard let app = copySource else { return reportMissingSelection() }
        // The palette holds key, so the ⌘C would land in its own search field.
        if windowController.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        Task {
            var context = context
            context.selection = await injector.copySelection(from: app) ?? ""
            guard let prompt = runnablePrompt(id: prompt.id) else { return }
            guard !context.selection.isEmpty else { return reportMissingSelection() }
            run(prompt, context: context, copySource: nil, values: values)
        }
    }

    private func reportMissingSelection() {
        core.showMessage(
            Permissions.isAccessibilityTrusted()
                ? "Couldn’t get the selected text"
                : "Allow Smallcast to use Accessibility in System Settings",
            tone: .danger)
    }

    // MARK: - Library

    /// The editor lives in Settings ▸ AI, so the palette steps aside for it.
    func edit(_ prompt: QuickPrompt?) {
        guard settings.aiEnabled else { return }
        if windowController.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        settingsCoordinator.showSettings(tab: .ai)
        editRequest = QuickPromptEditRequest(prompt: prompt)
    }

    /// Editing keeps the enabled flag as Settings last left it.
    func save(_ draft: QuickPrompt, isNew: Bool) throws {
        if isNew {
            try store.add(draft)
            return
        }
        guard let current = store.prompt(id: draft.id) else {
            throw QuickPromptCoordinatorError.deleted
        }
        var draft = draft
        draft.isEnabled = current.isEnabled
        try store.update(draft)
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        store.setEnabled(enabled, id: id)
    }

    func setShowsInRootSearch(_ shows: Bool, id: UUID) {
        store.setShowsInRootSearch(shows, id: id)
    }

    func delete(id: UUID) async {
        guard let prompt = store.prompt(id: id) else { return }
        guard
            await core.confirm(
                title: "Delete “\(prompt.name)”?",
                message: "Its fallback presets, favorite slot and learned ranking go with it.",
                symbol: prompt.symbol, confirmTitle: "Delete")
        else { return }
        store.remove(id: id)
        removeReferences(entryIDs: [prompt.entryID])
    }

    @discardableResult
    func replacePrompts(_ prompts: [QuickPrompt]) -> Int {
        let previous = store.prompts
        let count = store.replace(with: prompts)
        let liveIDs = Set(store.prompts.map(\.id))
        let removed = previous.filter { !liveIDs.contains($0.id) }
        removeReferences(entryIDs: Set(removed.map(\.entryID)))
        return count
    }

    /// Fallback presets are pruned by `FallbackCoordinator` whenever the library changes.
    private func removeReferences(entryIDs: Set<String>) {
        favorites.remove(keys: entryIDs)
        visibility.removeItemKeys(entryIDs)
        aliases.removeKeys(entryIDs)
        for entryID in entryIDs {
            ranking.reset(itemKey: entryID)
        }
    }
}

enum QuickPromptCoordinatorError: LocalizedError {
    case deleted

    var errorDescription: String? {
        "This prompt was deleted. Copy your changes before closing."
    }
}
