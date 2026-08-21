import Foundation

/// A saved chat. It has no title of its own — the first thing asked is the title, the way a mail
/// thread is named by its subject, so renaming can never drift from what the chat is about.
struct AIConversation: Identifiable, Hashable, Codable, Sendable {
    static let titleLimit = 60

    let id: UUID
    var messages: [AIMessage]
    var updatedAt: Date

    init(id: UUID = UUID(), messages: [AIMessage] = [], updatedAt: Date) {
        self.id = id
        self.messages = messages
        self.updatedAt = updatedAt
    }

    var title: String {
        Self.title(from: messages.first { $0.role == .user }?.text ?? "")
    }

    /// The turns worth sending back as context: a failed one asked nothing and answered nothing.
    var contextMessages: [AIMessage] {
        messages.filter { $0.failure == nil && !$0.isEmpty }
    }

    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "New Chat" }
        guard trimmed.count > titleLimit else { return trimmed }
        return String(trimmed.prefix(titleLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
