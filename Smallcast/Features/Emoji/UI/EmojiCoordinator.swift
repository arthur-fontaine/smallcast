import AppKit

/// Owns emoji delivery: frequency tallies the base glyph, the configured tone applies at copy time.
@MainActor
final class EmojiCoordinator {
    private let frequentEmoji: FrequentEmojiStore
    private let suggestions: EmojiSuggestionManager
    private let settings: AppSettings
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore

    init(
        frequentEmoji: FrequentEmojiStore,
        suggestions: EmojiSuggestionManager,
        settings: AppSettings,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.frequentEmoji = frequentEmoji
        self.suggestions = suggestions
        self.settings = settings
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    func pasteEmoji(_ entry: EmojiEntry) {
        frequentEmoji.record(entry.glyph)
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.pasteString(entry.display(tone: settings.emojiSkinTone), previousApp: previous)
    }

    func copyEmoji(_ entry: EmojiEntry) {
        frequentEmoji.record(entry.glyph)
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyString(entry.display(tone: settings.emojiSkinTone))
    }

    func pasteEmojiKeepingWindowOpen(_ entry: EmojiEntry) {
        frequentEmoji.record(entry.glyph)
        windowController.pasteStringKeepingWindowOpen(entry.display(tone: settings.emojiSkinTone))
    }

    // MARK: - Suggestions

    /// The switch funnels here so enabling, which is also consent, confirms first.
    func setSuggestionsEnabled(_ enabled: Bool) {
        guard enabled != settings.emojiSuggestionsEnabled else { return }
        if !enabled {
            settings.emojiSuggestionsEnabled = false
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        Task {
            let megabytes = Double(EmoModelStore.totalSize) / 1_000_000
            guard
                await core.confirm(
                    title: "Suggest emoji from what you type?",
                    message:
                        "Smallcast keeps the last sentence you type, in memory only, and needs the "
                        + "Accessibility permission to see it. It also downloads the "
                        + "\(String(format: "%.1f", megabytes)) MB Emo model from huggingface.co once.",
                    symbol: "face.smiling", confirmTitle: "Continue", tone: .neutral,
                    confirmRole: .standard)
            else { return }

            settings.emojiSuggestionsEnabled = true
            // The one prompt for this feature, raised from the gesture that asked for it.
            Permissions.ensureAccessibility()
        }
    }

    /// Reconciles everything the switch owns; off also deletes the downloaded model.
    func applySuggestionsEnabled() {
        suggestions.applyEnabled(settings.emojiSuggestionsEnabled)
        if !settings.emojiSuggestionsEnabled { suggestions.removeModel() }
    }
}
