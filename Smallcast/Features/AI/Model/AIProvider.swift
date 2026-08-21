import Foundation

/// The two API shapes Smallcast speaks. Both take the same request body; they differ in the path
/// they post to, whether they need a credential, and how they frame a streamed reply.
enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case openAICompatible = "openai"
    case lmStudio = "lmstudio"
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatible: return "OpenAI-Compatible"
        case .lmStudio: return "LM Studio"
        case .ollama: return "Ollama"
        }
    }

    /// Only a hosted endpoint authenticates; the two local servers have nothing to check against.
    var needsAPIKey: Bool { self == .openAICompatible }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        // LM Studio's own default port. It is configurable there, and often not 1234.
        case .lmStudio: return "http://localhost:1234/v1"
        case .ollama: return "http://localhost:11434"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o-mini"
        // LM Studio names a model by what was downloaded, so there is nothing to guess.
        case .lmStudio: return ""
        case .ollama: return "llama3.2"
        }
    }

    /// Appended to the base URL to reach the streaming chat endpoint.
    var chatPath: String {
        switch self {
        case .openAICompatible, .lmStudio: return "chat/completions"
        case .ollama: return "api/chat"
        }
    }

    /// Where the server lists what it can serve, so a model never has to be typed from memory.
    var modelsPath: String {
        switch self {
        case .openAICompatible, .lmStudio: return "models"
        case .ollama: return "api/tags"
        }
    }

    /// How a reply arrives: server-sent events for OpenAI, one JSON object per line for Ollama.
    var framing: AIStreamFraming {
        switch self {
        case .openAICompatible, .lmStudio: return .serverSentEvents
        case .ollama: return .newlineDelimitedJSON
        }
    }
}

enum AIStreamFraming: Sendable {
    case serverSentEvents
    case newlineDelimitedJSON
}
