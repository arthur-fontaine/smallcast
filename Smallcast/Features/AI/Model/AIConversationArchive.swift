import Foundation

/// The on-disk shape of saved chats, and the pruning the store applies before every write.
enum AIConversationArchive {
    static let conversationLimit = 200

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ conversations: [AIConversation]) throws -> Data {
        try encoder.encode(pruned(conversations))
    }

    static func decode(_ data: Data) throws -> [AIConversation] {
        pruned(try decoder.decode([AIConversation].self, from: data))
    }

    /// Newest first and capped. A chat with nothing in it is not history, so it never survives.
    static func pruned(
        _ conversations: [AIConversation], limit: Int = conversationLimit
    ) -> [AIConversation] {
        conversations
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }
}
