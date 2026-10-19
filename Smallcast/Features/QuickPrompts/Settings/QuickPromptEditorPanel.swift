import SwiftUI

struct QuickPromptEditorPanel: View {
    @Environment(\.settingsEditorDismiss) private var dismiss
    @Environment(QuickPromptCoordinator.self) private var coordinator

    private let existing: QuickPrompt?
    @State private var name: String
    @State private var iconSymbol: String?
    @State private var template: String
    @State private var showsInRootSearch: Bool
    @State private var failure: String?
    @State private var showingIconPicker = false

    private static let iconSymbols = [
        "text.bubble", "translate", "character.bubble", "quote.bubble", "sparkles", "wand.and.stars",
        "lightbulb", "brain", "book", "graduationcap", "doc.text", "list.bullet", "checklist",
        "envelope", "pencil.and.scribble", "textformat", "magnifyingglass", "globe",
        "chevron.left.forwardslash.chevron.right", "terminal", "ladybug", "chart.bar", "calendar",
        "fork.knife", "airplane", "heart", "star", "flag"
    ]

    private static let placeholder = "Translate {argument name=\"text\"} to {argument name=\"language\"}"

    init(request: QuickPromptEditRequest) {
        existing = request.prompt
        _name = State(initialValue: request.prompt?.name ?? "")
        _iconSymbol = State(initialValue: request.prompt?.iconSymbol)
        _template = State(initialValue: request.prompt?.template ?? "")
        _showsInRootSearch = State(initialValue: request.prompt?.showsInRootSearch ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsEditorHeader(
                title: existing == nil ? "New Quick Prompt" : "Edit \(existing?.name ?? "")",
                subtitle: "Fill its arguments at the launcher, then Quick AI answers it."
            )

            HStack(alignment: .bottom, spacing: Theme.Spacing.lg) {
                nameField
                iconField
            }

            templateField

            Toggle("Show in root search", isOn: $showsInRootSearch)
                .toggleStyle(.checkbox)

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.destructive)
            }

            HStack(spacing: Theme.Spacing.md) {
                if let existing {
                    Button("Delete", role: .destructive) {
                        dismiss()
                        Task { await coordinator.delete(id: existing.id) }
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

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Name")
                .font(.callout.weight(.medium))
            TextField("Translate", text: $name)
                .settingsEditorTextField()
        }
    }

    private var iconField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Icon")
                .font(.callout.weight(.medium))
            Button {
                showingIconPicker = true
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    SymbolImage(name: iconSymbol ?? QuickPrompt.sfSymbol, size: 14)
                    Text(iconSymbol == nil ? "Automatic" : "Custom")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(width: 120)
            }
            .popover(isPresented: $showingIconPicker, arrowEdge: .bottom) {
                SymbolPicker(
                    selection: $iconSymbol, fallback: QuickPrompt.sfSymbol,
                    suggested: Self.iconSymbols
                ) {
                    showingIconPicker = false
                }
            }
        }
    }

    private var templateField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Prompt")
                    .font(.callout.weight(.medium))
                Spacer()
                insertMenu
            }
            TextEditor(text: $template)
                .font(.body)
                .settingsEditorTextArea(height: Theme.Size.editorTextHeight * 2)
                .overlay(alignment: .topLeading) {
                    if template.isEmpty {
                        Text(Self.placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(Theme.Spacing.md)
                            .allowsHitTesting(false)
                    }
                }
            Text(argumentsSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var insertMenu: some View {
        Menu("Insert…") {
            Button("Named Argument") { insert("{argument name=\"text\"}") }
            Button("Argument with Choices") {
                insert("{argument name=\"language\" options=\"English, French\"}")
            }
            Button("Optional Argument") { insert("{argument name=\"tone\" default=\"neutral\"}") }
            Divider()
            Button("Selected Text") { insert("{selection}") }
            Button("Clipboard") { insert("{clipboard}") }
            Divider()
            Button("Date") { insert("{date}") }
            Button("Time") { insert("{time}") }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The fields the launcher will ask for, read off the template exactly as the row will.
    private var argumentsSummary: String {
        let names = SnippetTemplateEngine.declaredArguments(in: template).map(\.name)
        guard !names.isEmpty else {
            return "Add an {argument} to fill it at the launcher and offer the prompt as a fallback."
        }
        return "The launcher asks for: " + names.joined(separator: ", ") + "."
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// At the end: a `TextEditor` exposes no selection to insert at.
    private func insert(_ token: String) {
        let separator = template.isEmpty || template.hasSuffix(" ") || template.hasSuffix("\n") ? "" : " "
        template += separator + token
    }

    private func save() {
        let draft = QuickPrompt(
            id: existing?.id ?? UUID(), name: name, template: template, iconSymbol: iconSymbol,
            isEnabled: existing?.isEnabled ?? true, showsInRootSearch: showsInRootSearch)
        do {
            try coordinator.save(draft, isNew: existing == nil)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
