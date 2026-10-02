import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: $settings.clipboardEnabled) {
                    SettingsFeatureToggleLabel(
                        anchor: .clipboardClipboard, title: "Enable Clipboard History",
                        subtitle: "Keep copied items ready to reuse.")
                }
            }
            .settingsAnchor(.clipboardClipboard)

            FeatureCommandsSection(owner: .clipboard, anchor: .clipboardCommands)
                .settingsEnabled(settings.clipboardEnabled)

            Section {
                Toggle(isOn: $settings.tabOpensClipboard) {
                    SettingsRowTitle(.clipboardLauncher, "Tab opens the clipboard")
                    Text("From root search, through AI chat and back again. Off leaves Tab to the palette alone.")
                }
            } header: {
                SettingsSectionHeader(.clipboardLauncher)
            } footer: {
                Text(
                    "Tab always walks a selected row's argument fields first; it only reaches the "
                        + "clipboard when the row declares none."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $settings.clipboardRetention) {
                    ForEach(ClipboardRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                } label: {
                    SettingsRowTitle(.clipboardHistory, "Keep history for")
                }
                Toggle(isOn: $settings.clipboardTextSearchEnabled) {
                    SettingsRowTitle(.clipboardHistory, "Search text in images and PDFs")
                    Text("Recognized on this Mac while idle.")
                }
                Picker(selection: $settings.clipboardDefaultAction) {
                    ForEach(ClipboardDefaultAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                } label: {
                    SettingsRowTitle(.clipboardHistory, "Default action")
                    Text("↵ does this, and Paste takes its shortcut.")
                }
            } header: {
                SettingsSectionHeader(.clipboardHistory)
            }
            .settingsEnabled(settings.clipboardEnabled)

            DisabledApplicationsSection(
                bundleIDs: $settings.clipboardDisabledApps,
                anchor: .clipboardDisabledApplications,
                footer: "Copies from these apps aren't recorded."
            )
            .settingsEnabled(settings.clipboardEnabled)

            Section {
                LabeledContent {
                    Button("Clear…", role: .destructive) { confirmingClear = true }
                } label: {
                    SettingsRowTitle(.clipboardDisabledApplications, "Clear history")
                    Text("Removes every clip and image.")
                }
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.clipboard)
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                core.clipboardCoordinator.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }
}
