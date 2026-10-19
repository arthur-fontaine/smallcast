import SwiftUI

/// Settings ▸ Fallbacks: which commands a typed query is offered to, and in what order.
struct FallbacksSettingsView: View {
    @Environment(AppCore.self) private var core
    /// Observed so a reorder or a checkbox redraws the list under the button that moved it.
    @Environment(FallbackStore.self) private var store
    @State private var presetEditor: FallbackPresetEditRequest?

    private var fallbacks: [Fallback] { core.fallbackCoordinator.available }

    var body: some View {
        Form {
            Section {
                let fallbacks = fallbacks
                if fallbacks.isEmpty {
                    Text("Nothing to offer — their features are off.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(Array(fallbacks.enumerated()), id: \.element) { index, fallback in
                        FallbackRow(
                            fallback: fallback, order: fallbacks, index: index,
                            editPreset: { presetEditor = $0 })
                    }
                }
                Button {
                    presetEditor = FallbackPresetEditRequest(
                        preset: nil, target: core.fallbackCoordinator.presetTargets.first)
                } label: {
                    SettingsRowTitle(.fallbacksFallbacks, "Add Preset")
                }
                .disabled(core.fallbackCoordinator.presetTargets.isEmpty)
            } header: {
                SettingsSectionHeader(.fallbacksFallbacks)
            } footer: {
                Text(
                    "Shown below every search as “Use … with”. Includes quicklinks and quick prompts "
                        + "with an {argument}; a preset runs one under its own name, arguments given."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsEditorPanel(item: $presetEditor) { request in
            FallbackPresetEditorPanel(request: request)
        }
        .settingsScrollTarget(.fallbacks)
        .releasesFocusOnOutsideClick()
    }
}

private struct FallbackRow: View {
    let fallback: Fallback
    /// The visible order, so a move stores every id rather than only the two that swapped.
    let order: [Fallback]
    let index: Int
    let editPreset: (FallbackPresetEditRequest) -> Void

    @Environment(AppCore.self) private var core
    @Environment(FallbackStore.self) private var store

    var body: some View {
        if let entry = core.fallbackCoordinator.entry(for: fallback) {
            SettingsRow(title: entry.name, subtitle: subtitle(for: entry)) {
                AppIconView(app: entry)
                    .frame(width: SettingsListMetrics.iconSize, height: SettingsListMetrics.iconSize)
            } trailing: {
                presetButton
                Button {
                    move(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .accessibilityLabel("Move \(entry.name) up")
                Button {
                    move(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == order.count - 1)
                .accessibilityLabel("Move \(entry.name) down")
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("Offer \(entry.name) as a fallback")
            }
        }
    }

    /// A preset edits itself; a quicklink or prompt offers to start a preset on it.
    @ViewBuilder
    private var presetButton: some View {
        switch fallback {
        case .preset(let id):
            if let preset = store.preset(id: id) {
                Button {
                    editPreset(FallbackPresetEditRequest(preset: preset, target: nil))
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit Preset")
                .accessibilityLabel("Edit \(preset.name)")
            }
        case .quicklink(let id), .quickPrompt(let id):
            let target: FallbackPreset.Target =
                if case .quicklink = fallback { .quicklink(id) } else { .quickPrompt(id) }
            Button {
                editPreset(FallbackPresetEditRequest(preset: nil, target: target))
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .help("Add a Preset of This")
            .accessibilityLabel("Add a preset")
        case .builtin:
            EmptyView()
        }
    }

    /// A preset's entry carries its target's name, which says more than the shared kind label.
    private func subtitle(for entry: AppEntry) -> String {
        guard case .preset = fallback, let target = entry.subtitle else { return entry.kindLabel }
        return "\(entry.kindLabel) · \(target)"
    }

    private func move(by delta: Int) {
        guard order.indices.contains(index + delta) else { return }
        store.exchange(fallback, with: order[index + delta], in: order)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled(fallback) },
            set: { store.setEnabled($0, for: fallback) }
        )
    }
}
