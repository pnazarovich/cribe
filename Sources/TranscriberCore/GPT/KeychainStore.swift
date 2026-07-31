import Foundation
import Security

/// Хранилище секретов: generic-пароли в Keychain. Никаких UserDefaults и файлов.
public enum KeychainStore {
    public static let service = "online.nazarovych.transcriber"

    /// Аккаунты, которыми пользуется приложение.
    public static let apiKeyAccount = "openai-api-key"
    public static let codexTokensAccount = "codex-tokens"

    public static func get(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public static func set(_ data: Data, account: String) {
        let query = baseQuery(account)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    public static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    // MARK: - Helpers

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

extension KeychainStore {
    public static func getString(_ account: String) -> String? {
        get(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func setString(_ value: String, account: String) {
        set(Data(value.utf8), account: account)
    }
}
