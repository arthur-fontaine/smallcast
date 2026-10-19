import Foundation

/// A named fallback row over a quicklink or quick prompt, with some of its arguments given up front.
struct FallbackPreset: Codable, Hashable, Identifiable, Sendable {
    static let entryIDPrefix = "fallback-preset:"

    enum Target: Codable, Hashable, Sendable {
        case quicklink(UUID)
        case quickPrompt(UUID)
    }

    let id: UUID
    var name: String
    var target: Target
    /// Blank values are not stored: an argument left out is the one the query may fill.
    var values: [String: String]

    init(id: UUID = UUID(), name: String, target: Target, values: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.target = target
        self.values = values
    }

    var entryID: String { Self.entryIDPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryIDPrefix.count)))
    }

    /// The query takes the first argument nothing else answered, preferring one that is owed.
    static func values(
        filling query: String, into arguments: [SnippetTemplateEngine.DeclaredArgument],
        given: [String: String] = [:]
    ) -> [String: String] {
        let open = arguments.filter { (given[$0.name] ?? "").isEmpty }
        guard let target = open.first(where: { !$0.isOptional }) ?? open.first else { return given }
        var values = given
        values[target.name] = query
        return values
    }
}
