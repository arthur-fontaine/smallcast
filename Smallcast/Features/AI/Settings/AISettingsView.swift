import SwiftUI

struct AISettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: $settings.aiEnabled) {
                    Text("Enable AI")
                    Text(
                        """
                        Ask a question from the launcher and get a streamed answer. What you type is \
                        sent to the provider you choose below, and nowhere else.
                        """
                    )
                }
            } header: {
                Text("AI")
            }

            AIProviderSection()
                .settingsEnabled(settings.aiEnabled)
            AIChordSection()
                .settingsEnabled(settings.aiEnabled)
            AICommandsSection()
                .settingsEnabled(settings.aiEnabled)
            AIHistorySection()
                .settingsEnabled(settings.aiEnabled)
        }
        .formStyle(.grouped)
    }
}

private struct AIProviderSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AIKeyStore.self) private var keys
    @Environment(AppCore.self) private var core
    @State private var isTesting = false

    var body: some View {
        @Bindable var settings = settings
        @Bindable var keys = keys
        return Section {
            Picker("Provider", selection: $settings.aiProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .onChange(of: settings.aiProvider) { _, provider in adopt(provider) }

            TextField("Address", text: $settings.aiBaseURL, prompt: Text(settings.aiProvider.defaultBaseURL))
            AIModelRow()
            if settings.aiProvider.needsAPIKey {
                SecureField("API Key", text: $keys.key)
            }
            TextField(
                "Instructions", text: $settings.aiSystemPrompt,
                prompt: Text("Optional — how answers should be written"), axis: .vertical
            )
            .lineLimit(2...5)

            Button(isTesting ? "Testing…" : "Test Connection", action: test)
                .disabled(isTesting)
        } header: {
            Text("Provider")
        } footer: {
            Text(
                """
                Any endpoint that speaks the OpenAI chat API works, including a local one. \
                The API key is kept in your Keychain and never travels in a settings backup.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Switching provider carries its own address and model across, unless one was typed by hand.
    private func adopt(_ provider: AIProvider) {
        let others = AIProvider.allCases.filter { $0 != provider }
        if others.contains(where: { $0.defaultBaseURL == settings.aiBaseURL }) {
            settings.aiBaseURL = provider.defaultBaseURL
        }
        if others.contains(where: { $0.defaultModel == settings.aiModel }) {
            settings.aiModel = provider.defaultModel
        }
    }

    private func test() {
        isTesting = true
        Task {
            let failure = await core.aiCoordinator.testConnection()
            isTesting = false
            guard let failure else {
                core.showMessage("The provider answered")
                return
            }
            await core.showNotice(
                title: "Couldn’t Reach the Provider", message: failure, symbol: "sparkles",
                tone: .danger)
        }
    }
}

/// The model field, plus what the server says it can serve. LM Studio names a model by whatever was
/// downloaded, so typing one from memory is not realistic; the field stays free text either way, so a
/// listing endpoint that doesn't answer costs nothing.
private struct AIModelRow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCore.self) private var core
    @State private var models: [String] = []
    @State private var isLoading = false

    var body: some View {
        @Bindable var settings = settings
        return LabeledContent("Model") {
            HStack(spacing: Theme.Spacing.sm) {
                TextField(
                    "Model", text: $settings.aiModel,
                    prompt: Text(prompt)
                )
                .labelsHidden()
                Button(action: load) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help("Ask the server which models it can serve.")
                .accessibilityLabel("Load models")
                if !models.isEmpty {
                    Menu {
                        ForEach(models, id: \.self) { model in
                            Button(model) { settings.aiModel = model }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Choose a model")
                }
            }
        }
        // A stale list belongs to the old server, so it goes rather than being re-fetched unasked.
        .onChange(of: settings.aiProvider) { models = [] }
        .onChange(of: settings.aiBaseURL) { models = [] }
    }

    private var prompt: String {
        let fallback = settings.aiProvider.defaultModel
        return fallback.isEmpty ? "Load the list, or type a model id" : fallback
    }

    private func load() {
        isLoading = true
        Task {
            models = await core.aiCoordinator.availableModels()
            isLoading = false
        }
    }
}

private struct AIChordSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Section {
            Picker("Ask AI With", selection: $settings.aiChord) {
                ForEach(PaletteAIChord.allCases) { chord in
                    Text(chord.title).tag(chord)
                }
            }
        } header: {
            Text("Shortcut")
        } footer: {
            Text(
                """
                Pressed in the launcher, this hands whatever you have typed to the AI and sends it. \
                It works even when the search found nothing.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// The two AI commands carry a global shortcut and a launcher checkbox each, like Search Files.
private struct AICommandsSection: View {
    @Environment(VisibilityStore.self) private var visibility

    private static let commands: [CommandID] = [.askAI, .searchAIChats]

    var body: some View {
        Section {
            ForEach(Self.commands, id: \.self) { command in
                if let entry = CommandCatalog.entry(for: command) {
                    SettingsRow(title: entry.name) {
                        Image(systemName: command.sfSymbol)
                            .frame(width: Theme.Size.settingsRowIcon)
                    } trailing: {
                        if let action = command.hotKeyAction {
                            ShortcutRecorder(action: action, isQuiet: true)
                        }
                        Toggle("", isOn: visibilityBinding(entry))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Show \(entry.name) in launcher")
                    }
                }
            }
        } header: {
            Text("Commands")
        } footer: {
            Text("The shortcut works even when the command is hidden from the launcher.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func visibilityBinding(_ entry: AppEntry) -> Binding<Bool> {
        Binding(
            get: { visibility.isItemVisible(entry) },
            set: { visibility.setItemVisible($0, for: entry) })
    }
}

private struct AIHistorySection: View {
    @Environment(AIConversationStore.self) private var conversations
    @Environment(AppCore.self) private var core

    var body: some View {
        Section {
            LabeledContent("Saved Chats") {
                Text("\(conversations.conversations.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Delete All Chats…") {
                Task { await core.aiCoordinator.deleteAllChats() }
            }
            .disabled(conversations.conversations.isEmpty)
        } header: {
            Text("History")
        } footer: {
            Text(
                "Chats are kept on this Mac only, newest \(AIConversationArchive.conversationLimit) of them."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
