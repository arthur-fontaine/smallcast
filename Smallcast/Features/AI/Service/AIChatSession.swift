import Foundation

/// The conversation on screen and the request behind it. Effectful like `FileSearchSession`: it owns
/// the in-flight task, because "stop" is a piece of state and not a decision anyone else can make.
@MainActor
@Observable
final class AIChatSession {
    private(set) var conversation: AIConversation?
    private(set) var isStreaming = false
    /// The model is reasoning and has produced no answer text yet.
    private(set) var isThinking = false

    /// Resolved per request, so a Settings edit lands on the next question with no rewiring.
    @ObservationIgnored var configure: (() -> AIProviderConfig?)?
    /// Called after every completed turn, so the transcript on disk matches the one on screen.
    @ObservationIgnored var onChange: ((AIConversation) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?

    var messages: [AIMessage] { conversation?.messages ?? [] }
    var isEmpty: Bool { messages.isEmpty }

    /// True once there is an answer to regenerate.
    var canRegenerate: Bool { !isStreaming && messages.last?.role == .assistant }

    func open(_ conversation: AIConversation) {
        cancel()
        self.conversation = conversation
    }

    func reset() {
        cancel()
        conversation = nil
    }

    func ask(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cancel()
        var chat = conversation ?? AIConversation(updatedAt: Date())
        chat.messages.append(AIMessage(role: .user, text: trimmed, createdAt: Date()))
        chat.updatedAt = Date()
        conversation = chat
        onChange?(chat)
        stream()
    }

    /// ⌘R — drop the last answer and ask the same question again.
    func regenerate() {
        guard var chat = conversation, chat.messages.last?.role == .assistant else { return }
        cancel()
        chat.messages.removeLast()
        conversation = chat
        guard chat.messages.last?.role == .user else { return }
        stream()
    }

    /// Also the exit path: a half-streamed answer nobody waited for is not worth keeping.
    func cancel() {
        task?.cancel()
        task = nil
        isStreaming = false
        isThinking = false
        guard var chat = conversation, let last = chat.messages.last,
            last.role == .assistant, last.failure == nil, last.isEmpty
        else { return }
        chat.messages.removeLast()
        conversation = chat
    }

    private func stream() {
        guard let config = configure?() else {
            fail("Choose a provider and a model in Settings › AI first.")
            return
        }
        let context = conversation?.contextMessages ?? []
        conversation?.messages.append(AIMessage(role: .assistant, text: "", createdAt: Date()))
        isStreaming = true
        task = Task { [weak self] in
            for await event in AIClient.stream(config: config, messages: context) {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .delta(let text): self.receive(text)
                case .thinking: self.isThinking = true
                case .failed(let message): self.fail(message)
                }
            }
            self?.finish()
        }
    }

    private func receive(_ text: String) {
        guard var chat = conversation, let index = chat.messages.indices.last,
            chat.messages[index].role == .assistant
        else { return }
        isThinking = false
        chat.messages[index].text += text
        chat.updatedAt = Date()
        conversation = chat
    }

    /// A failed turn stays in the transcript rather than becoming a dialog: the question is still
    /// on screen, so the answer's own row is where the reason belongs.
    private func fail(_ message: String) {
        var chat = conversation ?? AIConversation(updatedAt: Date())
        if let index = chat.messages.indices.last, chat.messages[index].role == .assistant {
            chat.messages[index].failure = message
        } else {
            chat.messages.append(
                AIMessage(role: .assistant, text: "", createdAt: Date(), failure: message))
        }
        chat.updatedAt = Date()
        conversation = chat
        isStreaming = false
        isThinking = false
        onChange?(chat)
    }

    private func finish() {
        isStreaming = false
        isThinking = false
        guard var chat = conversation, let index = chat.messages.indices.last,
            chat.messages[index].role == .assistant
        else { return }
        if chat.messages[index].isEmpty, chat.messages[index].failure == nil {
            chat.messages[index].failure = "The provider answered with nothing."
        }
        chat.updatedAt = Date()
        conversation = chat
        onChange?(chat)
    }
}
