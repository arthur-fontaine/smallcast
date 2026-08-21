import Foundation

/// Saved chats, newest first. One JSON file, rewritten whole: a transcript is small and the list is
/// capped, so there is nothing an append-only format would buy.
@MainActor
@Observable
final class AIConversationStore {
    private(set) var conversations: [AIConversation] = []

    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = AppPaths.applicationSupport().appendingPathComponent("ai-conversations.json")) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL),
            let stored = try? AIConversationArchive.decode(data)
        else { return }
        conversations = stored
    }

    func conversation(id: UUID) -> AIConversation? {
        conversations.first { $0.id == id }
    }

    /// Upsert: the live chat is written back after every turn, so the file survives a crash mid-chat.
    func save(_ conversation: AIConversation) {
        guard !conversation.messages.isEmpty else { return }
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        persist()
    }

    func remove(id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        conversations = []
        persist()
    }

    private func persist() {
        conversations = AIConversationArchive.pruned(conversations)
        guard let data = try? AIConversationArchive.encode(conversations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
