import Foundation

/// A saved prompt whose `{argument}`s are filled at the launcher, then asked in Quick AI.
struct QuickPrompt: Codable, Hashable, Identifiable, Sendable {
    static let entryIDPrefix = "quick-prompt:"
    static let sfSymbol = "text.bubble"

    let id: UUID
    var name: String
    /// Expanded by `SnippetTemplateEngine`, so it speaks every token a snippet does.
    var template: String
    var iconSymbol: String?
    /// Off keeps the prompt and everything attached to it, but nothing may offer or run it.
    var isEnabled: Bool
    var showsInRootSearch: Bool

    init(
        id: UUID = UUID(), name: String, template: String, iconSymbol: String? = nil,
        isEnabled: Bool = true, showsInRootSearch: Bool = true
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.iconSymbol = iconSymbol
        self.isEnabled = isEnabled
        self.showsInRootSearch = showsInRootSearch
    }

    var symbol: String { iconSymbol ?? Self.sfSymbol }

    var entryID: String { Self.entryIDPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryIDPrefix.count)))
    }

    /// What a launcher row has to ask for before the prompt can be sent.
    var arguments: [SnippetTemplateEngine.DeclaredArgument] {
        SnippetTemplateEngine.declaredArguments(in: template)
    }

    static func precedes(_ lhs: QuickPrompt, _ rhs: QuickPrompt) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return order != .orderedSame
            ? order == .orderedAscending : lhs.id.uuidString < rhs.id.uuidString
    }

    // Hand-written, so an added field keeps an older backup decodable.
    private enum CodingKeys: String, CodingKey {
        case id, name, template, iconSymbol, isEnabled, showsInRootSearch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        template = try container.decode(String.self, forKey: .template)
        iconSymbol = try container.decodeIfPresent(String.self, forKey: .iconSymbol)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showsInRootSearch =
            try container.decodeIfPresent(Bool.self, forKey: .showsInRootSearch) ?? true
    }
}

enum QuickPromptError: LocalizedError, Equatable {
    case emptyName
    case emptyTemplate
    case duplicateName
    case invalidCharacter

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the prompt."
        case .emptyTemplate: return "Enter the prompt to send."
        case .duplicateName: return "A prompt with this name already exists."
        case .invalidCharacter: return "Names and prompts cannot contain null characters."
        }
    }
}

/// The prompt library, kept in defaults like custom commands: a short list of authored text.
@MainActor
@Observable
final class QuickPromptStore {
    private static let defaultsKey = "quickPrompts"

    private let defaults: UserDefaults
    /// Display order is `QuickPrompt.precedes`.
    private(set) var prompts: [QuickPrompt]
    @ObservationIgnored var onChange: (([QuickPrompt]) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded =
            defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([QuickPrompt].self, from: $0) } ?? []
        prompts = Self.sanitized(decoded)
        if prompts != decoded { persist() }
    }

    func prompt(id: UUID) -> QuickPrompt? {
        prompts.first { $0.id == id }
    }

    func prompt(entryID: String) -> QuickPrompt? {
        QuickPrompt.id(fromEntryID: entryID).flatMap(prompt)
    }

    @discardableResult
    func add(_ draft: QuickPrompt) throws(QuickPromptError) -> QuickPrompt {
        let value = try Self.validated(draft, against: prompts)
        commit(prompts + [value])
        return value
    }

    func update(_ draft: QuickPrompt) throws(QuickPromptError) {
        guard prompts.contains(where: { $0.id == draft.id }) else { return }
        let value = try Self.validated(draft, against: prompts)
        commit(prompts.map { $0.id == value.id ? value : $0 })
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard var value = prompt(id: id), value.isEnabled != enabled else { return }
        value.isEnabled = enabled
        commit(prompts.map { $0.id == id ? value : $0 })
    }

    func setShowsInRootSearch(_ shows: Bool, id: UUID) {
        guard var value = prompt(id: id), value.showsInRootSearch != shows else { return }
        value.showsInRootSearch = shows
        commit(prompts.map { $0.id == id ? value : $0 })
    }

    @discardableResult
    func remove(id: UUID) -> QuickPrompt? {
        guard let removed = prompt(id: id) else { return nil }
        commit(prompts.filter { $0.id != id })
        return removed
    }

    /// Replaces the whole set on backup import, dropping invalid and duplicate records.
    @discardableResult
    func replace(with incoming: [QuickPrompt]) -> Int {
        let updated = Self.sanitized(incoming)
        commit(updated)
        return updated.count
    }

    private func commit(_ updated: [QuickPrompt]) {
        let sorted = updated.sorted(by: QuickPrompt.precedes)
        guard sorted != prompts else { return }
        prompts = sorted
        persist()
        onChange?(sorted)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// `existing` is what the name must be unique against: the library, or a batch in progress.
    private static func validated(
        _ draft: QuickPrompt, against existing: [QuickPrompt]
    ) throws(QuickPromptError) -> QuickPrompt {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the ends: a prompt's inner line breaks are part of what it asks.
        value.template = draft.template.trimmingCharacters(in: .whitespacesAndNewlines)
        value.iconSymbol = draft.iconSymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.iconSymbol?.isEmpty == true { value.iconSymbol = nil }
        guard !value.name.isEmpty else { throw .emptyName }
        guard !value.template.isEmpty else { throw .emptyTemplate }
        guard !value.name.contains("\0"), !value.template.contains("\0") else {
            throw .invalidCharacter
        }
        guard
            !existing.contains(where: {
                $0.id != value.id
                    && $0.name.compare(value.name, options: .caseInsensitive) == .orderedSame
            })
        else { throw .duplicateName }
        return value
    }

    private static func sanitized(_ values: [QuickPrompt]) -> [QuickPrompt] {
        var ids = Set<UUID>()
        var result: [QuickPrompt] = []
        for value in values where ids.insert(value.id).inserted {
            guard let cleaned = try? validated(value, against: result) else { continue }
            result.append(cleaned)
        }
        return result.sorted(by: QuickPrompt.precedes)
    }
}
