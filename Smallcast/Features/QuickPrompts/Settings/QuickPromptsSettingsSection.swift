import SwiftUI

/// Settings ▸ AI's prompt library. The pane presents the editor, which the launcher's ⌘E opens too.
struct QuickPromptsSettingsSection: View {
    @Environment(QuickPromptStore.self) private var store
    @Environment(QuickPromptCoordinator.self) private var coordinator

    var body: some View {
        Section {
            if store.prompts.isEmpty {
                Text("No quick prompts yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.prompts) { prompt in
                    QuickPromptSettingsRow(prompt: prompt)
                }
            }
            Button {
                coordinator.edit(nil)
            } label: {
                SettingsRowTitle(.aiQuickPrompts, "Add Quick Prompt")
            }
        } header: {
            SettingsSectionHeader(.aiQuickPrompts)
        } footer: {
            Text(
                "Each {argument name=\"…\"} becomes a field beside the launcher's search. A prompt "
                    + "with one is offered under Fallbacks too."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct QuickPromptSettingsRow: View {
    let prompt: QuickPrompt

    @Environment(QuickPromptCoordinator.self) private var coordinator

    var body: some View {
        SettingsRow(title: prompt.name, subtitle: prompt.template) {
            SymbolImage(name: prompt.symbol, size: Theme.Size.settingsRowIcon - Theme.Spacing.xs)
                .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
        } trailing: {
            if !prompt.showsInRootSearch {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help("Hidden from root search")
            }

            // An alias only reaches the ranker through the root-search slice, so it dims with it.
            AliasField(key: prompt.entryID, name: prompt.name)
                .settingsEnabled(prompt.isEnabled && prompt.showsInRootSearch)

            Button {
                coordinator.edit(prompt)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit Quick Prompt")
            .accessibilityLabel("Edit \(prompt.name)")

            Button {
                Task { await coordinator.delete(id: prompt.id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete Quick Prompt")
            .accessibilityLabel("Delete \(prompt.name)")

            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Enabled")
                .accessibilityLabel("Enable \(prompt.name)")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { prompt.isEnabled },
            set: { coordinator.setEnabled($0, id: prompt.id) })
    }
}
