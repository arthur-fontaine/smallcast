import AppKit

/// Owns summoning the palette and nothing else; where and how big stays with the controller.
@MainActor
final class PaletteCoordinator {
    private let palette: PaletteState
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let fileSearch: FileSearchSession
    private let windowController: PaletteWindowController

    init(
        palette: PaletteState,
        settings: AppSettings,
        appIndex: AppIndex,
        fileSearch: FileSearchSession,
        windowController: PaletteWindowController
    ) {
        self.palette = palette
        self.settings = settings
        self.appIndex = appIndex
        self.fileSearch = fileSearch
        self.windowController = windowController
    }

    // MARK: - Palette control

    var isVisible: Bool { windowController.isVisible }

    /// The app an action acts on: the one displaced, else what a hotkey found frontmost.
    var targetApp: NSRunningApplication? {
        windowController.isVisible
            ? windowController.previousApp : NSWorkspace.shared.frontmostApplication
    }

    /// Hides from any screen, not just root search: the chord that summoned a sub-screen has to be
    /// able to put it away again, and `restoreAnyMode` brings that screen back on the next press.
    func togglePalette() {
        if windowController.isVisible {
            hidePalette(reason: .dismissed)
        } else {
            showPalette(mode: .launcher, restoreAnyMode: true)
        }
    }

    func toggleClipboard() {
        if windowController.isVisible, palette.mode == .clipboard {
            hidePalette(reason: .dismissed)
        } else {
            showPalette(mode: .clipboard)
        }
    }

    func toggleEmoji() {
        if windowController.isVisible, palette.mode == .emoji {
            hidePalette(reason: .dismissed)
        } else {
            showPalette(mode: .emoji)
        }
    }

    /// Shows the palette, honoring Pop to Root Search. See docs/features/palette.md#state-flow.
    func showPalette(mode: PaletteMode, restoreAnyMode: Bool = false) {
        let preserved = windowController.consumePreservedState()
        if !(preserved && (restoreAnyMode || palette.mode == mode)) {
            palette.prepare(mode: mode)
        }
        windowController.show()
        if palette.mode == .fileSearch { fileSearch.search(palette.query) }
        // Re-scan on open so an app uninstalled since the last scan drops out of the launcher.
        if palette.mode == .launcher { Task { await appIndex.refresh() } }
    }

    /// `reason` defaults to `.actionTaken`: every caller that hides the palette because something ran
    /// wants the next summon to start clean. The three dismissal paths (Escape, the toggle hotkeys and
    /// clicking away) say so explicitly, and only those hold on to what was typed.
    func hidePalette(restoreFocus: Bool = true, reason: PaletteHideReason = .actionTaken) {
        fileSearch.cancel()
        windowController.hide(restoreFocus: restoreFocus, reason: reason)
    }

    /// True for the slim compact bar: compact on, launcher root, empty, not overflowed.
    var paletteIsCollapsed: Bool {
        settings.compactMode
            && !palette.forceExpanded
            && palette.mode == .launcher
            && palette.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The compact bar's overflow: expand into the full launcher without typing.
    /// Escape's "go back" — the same one step a bare backspace takes.
    @discardableResult
    func exitScreen() -> Bool { windowController.exitScreen() }

    func expandFromCompact() {
        palette.forceExpanded = true
    }

    /// Resize the panel to the current collapsed state, when it flips while open.
    func syncPaletteSize() {
        windowController.applyCollapsed(paletteIsCollapsed)
    }

    // MARK: - Dragging

    /// Bracket one drag gesture; the handle tracks it from mouse-down to mouse-up itself.
    func beginPaletteDrag() {
        windowController.beginDrag()
    }

    func endPaletteDrag() {
        windowController.endDrag()
    }
}
