import AppKit

/// The one funnel into the AI feature: the chord, both commands and every ⌘K row land here.
@MainActor
final class AICoordinator {
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let session: AIChatSession
    private let conversations: AIConversationStore
    private let keys: AIKeyStore
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private unowned let core: AppCore

    init(
        settings: AppSettings, appIndex: AppIndex, session: AIChatSession,
        conversations: AIConversationStore, keys: AIKeyStore, palette: PaletteState,
        paletteCoordinator: PaletteCoordinator, core: AppCore
    ) {
        self.settings = settings
        self.appIndex = appIndex
        self.session = session
        self.conversations = conversations
        self.keys = keys
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.core = core
        session.configure = { [weak self] in self?.config }
        session.onChange = { [weak self] in self?.conversations.save($0) }
    }

    /// Off means fully off: no commands, no chord, and nothing left mid-stream.
    func applyEnabled() {
        appIndex.setCommandsVisible([.askAI, .searchAIChats], settings.aiEnabled)
        guard !settings.aiEnabled else { return }
        session.reset()
        if palette.mode == .aiChat || palette.mode == .aiChats {
            palette.prepare(mode: .launcher)
        }
    }

    /// What the server says it can serve. Built from the typed address rather than `config`, which
    /// requires a model — the whole point of asking is that no model is chosen yet.
    func availableModels() async -> [String] {
        await AIClient.models(
            config: AIProviderConfig(
                provider: settings.aiProvider, baseURL: settings.aiBaseURL,
                model: settings.aiModel, apiKey: keys.storedKey))
    }

    /// What a request is made with; nil until there is enough to make one.
    var config: AIProviderConfig? {
        let config = AIProviderConfig(
            provider: settings.aiProvider, baseURL: settings.aiBaseURL, model: settings.aiModel,
            apiKey: keys.storedKey, systemPrompt: settings.aiSystemPrompt)
        return config.isUsable ? config : nil
    }

    /// The chord from root search, and the Ask AI command. Always a fresh conversation: the point of
    /// the chord is that what was typed is the whole question.
    func askAI(prompt: String) {
        guard settings.aiEnabled else { return }
        session.reset()
        paletteCoordinator.showPalette(mode: .aiChat)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.ask(trimmed)
    }

    /// A follow-up typed into the composer; the field is cleared so it reads as sent.
    func send(_ prompt: String) {
        guard settings.aiEnabled, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        session.ask(prompt)
        palette.query = ""
    }

    func newChat() {
        guard settings.aiEnabled else { return }
        session.reset()
        paletteCoordinator.showPalette(mode: .aiChat)
    }

    func showChats() {
        guard settings.aiEnabled else { return }
        paletteCoordinator.showPalette(mode: .aiChats)
    }

    func open(_ conversation: AIConversation) {
        guard settings.aiEnabled else { return }
        session.open(conversation)
        paletteCoordinator.showPalette(mode: .aiChat)
    }

    func stop() {
        session.cancel()
    }

    func regenerate() {
        session.regenerate()
    }

    func copyAnswer(_ message: AIMessage) {
        guard !message.isEmpty else { return }
        Paster.copyPlainText(message.text)
        core.showMessage("Copied answer")
    }

    func delete(_ conversation: AIConversation) {
        conversations.remove(id: conversation.id)
        // The chat on screen is the one that just went away; leave nothing pointing at it.
        if session.conversation?.id == conversation.id { session.reset() }
    }

    func deleteAllChats() async {
        guard !conversations.conversations.isEmpty else { return }
        let confirmed = await core.confirm(
            title: "Delete All Chats?",
            message: "Every saved conversation is removed from this Mac. This can't be undone.",
            symbol: "bubble.left.and.bubble.right", confirmTitle: "Delete All")
        guard confirmed else { return }
        conversations.removeAll()
        session.reset()
    }

    /// Settings' Test Connection button: nil means the endpoint answered.
    func testConnection() async -> String? {
        guard let config else {
            return "Fill in the address, the model and — for a hosted provider — the API key."
        }
        return await AIClient.probe(config: config)
    }
}
