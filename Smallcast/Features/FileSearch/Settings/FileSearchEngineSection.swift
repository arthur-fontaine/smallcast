import SwiftUI

/// How File Search finds files; laid out like Dictation's engine, which also waits on an install.
struct FileSearchEngineSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var draftPath = ""

    private var state: DigUpState { core.digUpState }

    var body: some View {
        @Bindable var settings = settings
        return Section {
            Picker(selection: $settings.fileSearchEngine) {
                ForEach(FileSearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            } label: {
                SettingsRowTitle(.fileSearchEngine, "Find files by")
                Text(settings.fileSearchEngine.summary)
            }

            if settings.fileSearchEngine == .nameAndContent {
                LabeledContent {
                    HStack(spacing: Theme.Spacing.lg) {
                        if state.helper == nil {
                            Button("Check Again", action: refresh)
                        }
                        if state.availability == .notInstalled {
                            Button("Get DigUp…") { NSWorkspace.shared.open(DigUpLocator.downloadURL) }
                        }
                        if state.helper != nil, !state.isSetUp || state.serviceFailed {
                            Button("Open DigUp") { core.fileSearchCoordinator.openDigUp() }
                        }
                    }
                } label: {
                    Text(statusTitle)
                    Text(statusDetail)
                }

                TextField(text: $draftPath, prompt: Text("DigUp.app’s own")) {
                    SettingsRowTitle(.fileSearchEngine, "DigUp helper")
                    Text("Only for a digup built from source.")
                }
                .onSubmit(commitPath)
            }
        } header: {
            SettingsSectionHeader(.fileSearchEngine)
        }
        .onAppear {
            draftPath = settings.fileSearchDigUpPath
            refresh()
        }
        .onChange(of: settings.fileSearchEngine) { _, engine in
            if engine == .nameAndContent { Task { await core.fileSearchCoordinator.offerDigUpSetup() } }
        }
        .task {
            // Back from DigUp's onboarding, the status should say so without reopening Settings.
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification)
            {
                refresh()
            }
        }
    }

    private var statusTitle: String {
        switch state.availability {
        case .found:
            if !state.isSetUp { return "DigUp isn’t set up" }
            return state.serviceFailed ? "DigUp couldn’t start searching" : "DigUp installed"
        case .notInstalled: return "DigUp not installed"
        case .missingCustomPath: return "DigUp helper not found"
        }
    }

    private var statusDetail: String {
        switch state.availability {
        case .found:
            guard state.isSetUp else {
                return "Choose its folders in DigUp. Until then, File Search finds files by name."
            }
            if state.serviceFailed {
                return "It needs DigUp 0.6.1 or later and a finished first index. Until then, File "
                    + "Search finds files by name."
            }
            guard !state.folders.roots.isEmpty, state.reachableRoots.isEmpty else {
                return "Searches inside the folders you chose in DigUp, as far as the scopes below reach."
            }
            return "None of DigUp’s folders is in the scopes below, so it finds nothing inside files."
        case .notInstalled: return "Until it is, File Search finds files by name."
        case .missingCustomPath(let path): return "Nothing that runs is at \(path)."
        }
    }

    private func commitPath() {
        let path = draftPath.trimmingCharacters(in: .whitespaces)
        draftPath = path
        if path != settings.fileSearchDigUpPath { settings.fileSearchDigUpPath = path }
        refresh()
    }

    private func refresh() {
        state.refresh(customPath: settings.fileSearchDigUpPath)
    }
}
