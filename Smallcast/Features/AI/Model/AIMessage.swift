import Foundation

/// One turn of a conversation. `failure` carries what went wrong instead of a thrown error, so a
/// failed turn stays in the transcript and can be regenerated where it stands.
struct AIMessage: Identifiable, Hashable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    var failure: String?

    init(id: UUID = UUID(), role: Role, text: String, createdAt: Date, failure: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.failure = failure
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
