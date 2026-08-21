import Foundation

/// What a server says it can serve. LM Studio names a model by whatever was downloaded, so typing
/// one from memory is not realistic — this is what the Settings pane fills its menu from.
enum AIModelList {
    /// Sorted, deduplicated, and with the embedding models dropped: they cannot answer a chat, and
    /// LM Studio lists them alongside the ones that can.
    static func decode(_ data: Data, provider: AIProvider) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let names: [String]
        switch provider {
        case .openAICompatible, .lmStudio:
            names = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .ollama:
            names = (object["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        return Set(names.filter { !$0.isEmpty && !isEmbedding($0) })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Name-based, because no listing endpoint reports what a model is for. Both servers spell it
    /// the same way, and a chat model called "…embedding…" is not a thing.
    private static func isEmbedding(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("embedding")
            || name.localizedCaseInsensitiveContains("embed-")
    }
}
