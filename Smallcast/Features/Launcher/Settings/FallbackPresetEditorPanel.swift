import SwiftUI

struct FallbackPresetEditRequest: Identifiable {
    let id = UUID()
    let preset: FallbackPreset?
    /// What a new preset starts on: the row its button was pressed on, or the first one offered.
    let target: FallbackPreset.Target?
}

/// A preset's name, what it runs, and the arguments it gives up front. The query fills the rest.
struct FallbackPresetEditorPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(AppCore.self) private var core

    private let existing: FallbackPreset?
    @State private var name: String
    @State private var target: FallbackPreset.Target?
    @State private var values: [String: String]

    init(request: FallbackPresetEditRequest) {
        existing = request.preset
        _name = State(initialValue: request.preset?.name ?? "")
        _target = State(initialValue: request.preset?.target ?? request.target)
        _values = State(initialValue: request.preset?.values ?? [:])
    }

    private var coordinator: FallbackCoordinator { core.fallbackCoordinator }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: existing == nil ? "New Fallback Preset" : "Edit \(existing?.name ?? "")",
                subtitle: "Runs a quicklink or quick prompt under its own name, with arguments given."
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Name")
                    .font(.callout.weight(.medium))
                TextField(targetName ?? "Name", text: $name)
                    .settingsEditorTextField()
            }

            Picker("Runs", selection: $target) {
                ForEach(coordinator.presetTargets, id: \.self) { candidate in
                    Text(coordinator.entry(for: candidate)?.name ?? "").tag(Optional(candidate))
                }
            }

            argumentFields

            HStack(spacing: Theme.Spacing.md) {
                if let existing {
                    Button("Delete", role: .destructive) {
                        coordinator.deletePreset(id: existing.id)
                        dismiss()
                    }
                    .buttonStyle(.modalAction(.destructive, fillsWidth: false))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.modalAction(.cancel))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: Theme.Size.editorSheetWidth)
        .settingsEditorPanelSurface()
    }

    private var arguments: [SnippetTemplateEngine.DeclaredArgument] {
        target.map(coordinator.arguments(of:)) ?? []
    }

    private var targetName: String? {
        target.flatMap(coordinator.entry(for:))?.name
    }

    @ViewBuilder
    private var argumentFields: some View {
        let arguments = arguments
        if !arguments.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Arguments")
                    .font(.callout.weight(.medium))
                ForEach(arguments, id: \.name) { argument in
                    LabeledContent(argument.name) {
                        TextField("", text: value(argument.name), prompt: Text(prompt(for: argument)))
                            .settingsEditorTextField()
                    }
                }
                Text(queryNote(for: arguments))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func prompt(for argument: SnippetTemplateEngine.DeclaredArgument) -> String {
        argument.options.isEmpty ? "Left empty" : argument.options.joined(separator: ", ")
    }

    /// Says which field the typed query lands in, by the same rule the run uses.
    private func queryNote(for arguments: [SnippetTemplateEngine.DeclaredArgument]) -> String {
        let filled = FallbackPreset.values(filling: "\u{0}", into: arguments, given: values)
        guard let receiver = filled.first(where: { $0.value == "\u{0}" })?.key else {
            return "Every argument is given, so what you type is not used."
        }
        return "What you type fills \u{201C}\(receiver)\u{201D}; any other empty argument is asked for."
    }

    private func value(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private var canSave: Bool {
        target != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let target else { return }
        // Only the target's own arguments: switching targets must not carry stale values along.
        let names = Set(arguments.map(\.name))
        coordinator.savePreset(
            FallbackPreset(
                id: existing?.id ?? UUID(), name: name, target: target,
                values: values.filter { names.contains($0.key) }))
        dismiss()
    }
}
