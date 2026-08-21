import AppKit

@MainActor
final class FileSearchCoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let session: FileSearchSession
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore

    init(
        settings: AppSettings, appIndex: AppIndex, session: FileSearchSession,
        palette: PaletteState, paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.session = session
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.searchFiles], settings.fileSearchEnabled)
        guard !settings.fileSearchEnabled else { return }
        session.cancel()
        if palette.mode == .fileSearch { palette.prepare(mode: .launcher) }
    }

    func applyPolicy() {
        session.apply(
            scopes: settings.fileSearchScopes, ignorePatterns: settings.fileSearchIgnorePatterns)
    }

    func show() {
        guard settings.fileSearchEnabled else { return }
        paletteCoordinator.showPalette(mode: .fileSearch)
    }

    /// The fallback row's path: `showPalette` clears the field, so the query is put back after it
    /// and the search kicked off by hand — the palette only searches on its own on a fresh show.
    func show(query: String) {
        guard settings.fileSearchEnabled else { return }
        paletteCoordinator.showPalette(mode: .fileSearch)
        palette.query = query
        session.search(query)
    }

    func open(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    result.url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                await core.showNotice(
                    title: "Couldn’t Open \(result.name)",
                    message: error.localizedDescription,
                    symbol: result.isDirectory ? "folder" : "doc", tone: .danger)
            }
        }
    }

    func showInFinder(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(result.url)
    }

    func copyPath(_ result: FileSearchResult) {
        Paster.copyPlainText(result.id)
        core.showMessage("Copied path")
    }
}
