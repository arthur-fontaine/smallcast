import Foundation

@MainActor
enum AIProviderFactory {
    static func make(
        settings: AISettingsStore,
        subscription: ChatGPTSubscriptionManager,
        keyStore: APIKeyStore = APIKeyStore()
    ) throws -> any AIProvider {
        guard let selection = settings.defaultModel else {
            throw AIProviderError.unavailable("Choose a default AI model in Settings.")
        }
        switch selection {
        case .chatGPT(let model, let effort):
            return ChatGPTSubscriptionProvider(
                turns: subscription.turns, model: model, effort: effort)
        case .api(let connectionID, let model):
            guard let connection = settings.connection(id: connectionID) else {
                throw AIProviderError.unavailable("Choose an API connection in Settings.")
            }
            let baseURL: URL
            do {
                baseURL = try AIEndpointPolicy.validate(connection.baseURL)
            } catch let error as AIEndpointPolicy.ValidationError {
                throw AIProviderError.unavailable(error.localizedDescription)
            }
            let key: String
            do {
                key = try keyStore.key(for: connection.id) ?? ""
            } catch {
                throw AIProviderError.unavailable("The API key could not be read from Keychain.")
            }
            guard AIEndpointPolicy.isLoopback(connection.baseURL) || !key.isEmpty else {
                throw AIProviderError.unavailable("Add an API key in Settings.")
            }
            return HTTPAIProvider(
                configuration: AIHTTPConfiguration(
                    provider: connection.provider, baseURL: baseURL, model: model),
                apiKey: key)
        }
    }
}
