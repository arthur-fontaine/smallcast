import Foundation

/// Everything a request needs, gathered before it leaves the main actor. The key is passed in
/// rather than read here: this layer never touches the Keychain.
struct AIProviderConfig: Hashable, Sendable {
    let provider: AIProvider
    let baseURL: String
    let model: String
    let apiKey: String?
    /// Prepended as a `system` turn when set; empty means the provider's own default persona.
    let systemPrompt: String

    init(
        provider: AIProvider, baseURL: String, model: String, apiKey: String? = nil,
        systemPrompt: String = ""
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
    }

    /// What the settings pane reports as "ready to ask", and what the coordinator refuses without.
    var isUsable: Bool {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty,
            Self.endpoint(baseURL: baseURL, path: provider.chatPath) != nil
        else { return false }
        return !provider.needsAPIKey || !(apiKey ?? "").isEmpty
    }

    /// Trailing slashes are stripped so a pasted base URL can't produce a doubled path separator.
    /// The scheme is checked against http(s) rather than merely being present: `localhost:11434`
    /// parses as a URL whose *scheme* is `localhost`, which would otherwise read as valid.
    static func endpoint(baseURL: String, path: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/" + path),
            url.scheme == "http" || url.scheme == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
