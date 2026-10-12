import SwiftUI

/// DigUp's matches below root search. Locked, and saying why, until its helper is found.
struct DigUpSettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var draftPath = ""

    private var state: DigUpState { core.digUpState }

    /// Reads off while locked, so a stored "on" never looks like it is doing something.
    private var enabled: Binding<Bool> {
        Binding(
            get: { settings.fileSearchDigUpEnabled && state.helper != nil },
            set: { settings.fileSearchDigUpEnabled = $0 })
    }

    var body: some View {
        Section {
            Toggle(isOn: enabled) {
                SettingsRowTitle(.fileSearchDigUp, "Show DigUp results in root search")
                Text("Replaces the Search Files fallback with the files DigUp finds by their content.")
            }
            .disabled(state.helper == nil)

            LabeledContent("Status") {
                HStack(spacing: Theme.Spacing.lg) {
                    Text(statusTitle)
                        .foregroundStyle(state.helper == nil ? .secondary : .primary)
                    if state.helper == nil {
                        Button("Check Again", action: refresh)
                        if state.availability == .notInstalled {
                            Button("Get DigUp…") { NSWorkspace.shared.open(DigUpLocator.downloadURL) }
                        }
                    }
                }
            }

            TextField(text: $draftPath, prompt: Text("Automatic: DigUp.app’s own helper")) {
                SettingsRowTitle(.fileSearchDigUp, "Helper path")
                Text("The `digup` command-line tool, for a build from source.")
            }
            .onSubmit(commitPath)
        } header: {
            SettingsSectionHeader(.fileSearchDigUp)
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            draftPath = settings.fileSearchDigUpPath
            refresh()
        }
    }

    private var statusTitle: String {
        switch state.availability {
        case .found: return "Found"
        case .notInstalled: return "Not installed"
        case .missingCustomPath: return "Not found"
        }
    }

    private var footer: String {
        switch state.availability {
        case .found(let helper):
            return "Uses \(helper.path). DigUp searches only the folders you chose in DigUp."
        case .notInstalled:
            return "DigUp isn’t installed. Install it, choose the folders it indexes, then check again."
        case .missingCustomPath(let path):
            return "Nothing that runs is at \(path). Clear the path to use DigUp.app’s own helper."
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
