import AppKit

@MainActor
final class FileSearchCoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let session: FileSearchSession
    private let indexer: FileIndexer
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let windowController: PaletteWindowController
    private var sharePicker: NSSharingServicePicker?
    private var launcherAnswers = false
    private unowned let core: AppCore

    init(
        settings: AppSettings, appIndex: AppIndex, session: FileSearchSession,
        indexer: FileIndexer, palette: PaletteState, paletteCoordinator: PaletteCoordinator,
        windowController: PaletteWindowController, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.session = session
        self.indexer = indexer
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.windowController = windowController
        self.core = core
        indexer.onIndexChanged = { [weak session] in session?.refresh() }
        indexer.onRecentChanged = { [weak session] in session?.refreshRecent() }
        session.onRepublish = { [palette] old, new in
            Self.keepSelection(on: palette, from: old, to: new)
        }
    }

    /// DigUp's rows land above the names a moment later; the selection stays on the same file.
    private static func keepSelection(
        on palette: PaletteState, from old: [FileSearchResult], to new: [FileSearchResult]
    ) {
        guard palette.mode == .fileSearch, palette.selection > 0,
            old.indices.contains(palette.selection),
            let index = new.firstIndex(where: { $0.id == old[palette.selection].id })
        else { return }
        palette.selection = index
    }

    func applyEnabled() {
        appIndex.setCommandsVisible([.searchFiles], settings.fileSearchEnabled)
        indexer.setEnabled(settings.fileSearchEnabled)
        guard !settings.fileSearchEnabled else { return }
        session.cancel()
        if palette.mode == .fileSearch { palette.prepare(mode: .launcher) }
    }

    func applyPolicy() {
        let policy = FileSearchPolicy(
            scopes: settings.fileSearchScopes,
            ignorePatterns: settings.fileSearchEffectiveIgnorePatterns,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        indexer.apply(policy)
        // DigUp indexes its own folders; what File Search may show is still File Search's to say.
        core.digUpState.apply(policy)
        if session.digUp != nil {
            session.digUp = core.digUpState.search(limit: DigUpSearchPolicy.panelLimit)
        }
    }

    /// DigUp's service runs only while something can ask it: File Search on, Name and content.
    func applyDigUp() {
        core.digUpState.setEnabled(
            settings.fileSearchEnabled && settings.fileSearchEngine == .nameAndContent,
            customPath: settings.fileSearchDigUpPath)
    }

    var showsFilesInLauncher: Bool {
        settings.fileSearchEnabled && settings.fileSearchShowInLauncher
    }

    /// Borrows the screen's session, so Search Files then opens on the request already answered.
    func searchFromLauncher(_ query: String) {
        guard showsFilesInLauncher, FileSearchQuery.answersLauncher(query) else {
            launcherAnswers = false
            session.cancel()
            return
        }
        // The query just became long enough: when to catch up with DigUp's indexing.
        if !launcherAnswers { core.digUpState.prepare(prewarming: false) }
        launcherAnswers = true
        session.digUp = core.digUpState.search(limit: DigUpSearchPolicy.panelLimit)
        session.search(query)
    }

    /// Checks the switch before reading the session, so with it off the launcher observes nothing.
    func launcherFiles(for query: String) -> [FileSearchResult] {
        guard showsFilesInLauncher, FileSearchQuery.answersLauncher(query) else { return [] }
        return Array(session.results.prefix(FileSearchQuery.launcherLimit))
    }

    func applyLauncherFiles() {
        guard palette.mode == .launcher else { return }
        searchFromLauncher(palette.query)
    }

    func rebuildIndex() {
        indexer.rebuild()
    }

    func openFullDiskAccessSettings() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Permissions.openFullDiskAccessSettings()
    }

    /// `query` is the fallback row's: the screen opens already narrowed to what was typed.
    func show(query: String = "") {
        guard settings.fileSearchEnabled else { return }
        indexer.refreshAccess()
        // DigUp's folders and index change in its own app, so they are read again at every entry.
        core.digUpState.refresh(customPath: settings.fileSearchDigUpPath)
        core.digUpState.prepare(prewarming: true)
        session.digUp = core.digUpState.search(limit: DigUpSearchPolicy.panelLimit)
        paletteCoordinator.togglePalette(mode: .fileSearch, seeding: query.isEmpty ? nil : query)
    }

    /// DigUp's own onboarding picks the folders and keeps them indexed; Smallcast only points there.
    func offerDigUpSetup() async {
        core.digUpState.refresh(customPath: settings.fileSearchDigUpPath)
        guard core.digUpState.helper != nil, !core.digUpState.isSetUp else { return }
        let open = await core.confirm(
            title: "Set Up DigUp?",
            message: """
                DigUp searches only the folders you choose in it. Until then, File Search finds \
                files by name.
                """,
            symbol: "sparkle.magnifyingglass", confirmTitle: "Open DigUp", tone: .neutral,
            confirmRole: .standard, dismissTitle: "Not Now")
        if open { openDigUp() }
    }

    func openDigUp() {
        let app =
            core.digUpState.helper.flatMap(DigUpLocator.app(containing:))
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: DigUpLocator.bundleIdentifier)
        guard let app else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func open(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Task {
            do {
                _ = try await NSWorkspace.shared.open(
                    result.url, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                await core.showNotice(
                    title: String(localized: "Couldn’t Open \(result.name)"),
                    message: error.localizedDescription,
                    symbol: result.isDirectory ? "folder" : "doc", tone: .danger)
            }
        }
    }

    func showInFinder(_ result: FileSearchResult) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.showInFinder(result.url)
    }

    /// macOS's own share sheet, anchored to the palette's trailing edge so the row stays beside it.
    func share(_ result: FileSearchResult) {
        guard let provider = NSItemProvider(contentsOf: result.url),
            let anchor = paletteCoordinator.anchorView
        else { return }
        let picker = NSSharingServicePicker(items: [provider])
        sharePicker = picker
        picker.show(
            relativeTo: CGRect(
                x: anchor.bounds.maxX, y: anchor.bounds.midY, width: 0, height: 0),
            of: anchor, preferredEdge: .maxX)
    }

    func copyPath(_ result: FileSearchResult) {
        Paster.copyPlainText(result.id)
        core.showMessage(String(localized: "Copied path"))
    }

    func copyName(_ result: FileSearchResult) {
        Paster.copyPlainText(result.name)
        core.showMessage(String(localized: "Copied name"))
    }

    /// The file itself rather than its path, so Finder and Mail paste a copy of it.
    func copyFile(_ result: FileSearchResult) {
        PasteboardFiles.write(result.url, to: .general)
        core.showMessage(String(localized: "Copied file"))
    }

    /// Into whichever app the palette was summoned over, which is what the row's title names.
    func pasteFile(_ result: FileSearchResult) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.pasteFile(result.url, previousApp: previous)
    }

    func trash(_ result: FileSearchResult) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
                }.value
                session.remove(result)
                core.showMessage(String(localized: "Moved to Trash"))
            } catch {
                await core.showNotice(
                    title: String(localized: "Couldn’t Move \(result.name) to Trash"),
                    message: error.localizedDescription,
                    symbol: "trash", tone: .danger)
            }
        }
    }
}
