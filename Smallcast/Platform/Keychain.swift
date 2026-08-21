import Foundation
import Security

/// The one place a secret is stored. Nothing secret goes through `AppSettings`: a settings backup
/// enumerates those keys, and a credential must never be able to ride one to another Mac.
enum Keychain {
    /// Scoped to the running bundle, so `Smallcast Dev` never reads the installed app's secrets.
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.smallcast.app"
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func read(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writing an empty string deletes the item, so "cleared the field" and "no secret" agree.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8), !value.isEmpty else { return delete(account) }
        let request = query(account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        return SecItemAdd(request.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
