import Foundation

/// The API key, held in memory for the requests that need it and persisted only to the Keychain.
/// Deliberately not an `AppSettings` value: those are what a settings backup enumerates.
@MainActor
@Observable
final class AIKeyStore {
    private static let account = "ai.apiKey"

    var key: String {
        didSet {
            guard key != oldValue else { return }
            Keychain.write(key, account: Self.account)
        }
    }

    init() {
        key = Keychain.read(Self.account) ?? ""
    }

    /// What a request should carry: nil rather than an empty string, so no blank header is sent.
    var storedKey: String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
