import Foundation
import Security

/// Хранилище секретов: связка ключей macOS, современная её половина (data protection keychain,
/// флаг `kSecUseDataProtectionKeychain`). Право на запись там даёт entitlement приложения
/// (`keychain-access-groups`), а не ACL конкретного бинарника, — поэтому пересборка и обновление
/// не выглядят для системы «другой программой» и пароль от связки больше не спрашивается.
/// В старой file-based связке ACL привязан к подписи кода, и каждая пересборка поднимала диалог.
///
/// Подписи без нужного entitlement система отвечает `errSecMissingEntitlement` — тогда один раз
/// сообщаем об этом в stderr и молча уходим на старую связку: всё работает, просто по-старому.
public final class SecretStore: @unchecked Sendable {
    public static let shared = SecretStore(modern: .dataProtection, legacy: .legacy)

    /// Аккаунты, которыми пользуется приложение.
    public static let apiKeyAccount = "openai-api-key"
    public static let codexTokensAccount = "codex-tokens"

    private let modern: KeychainAccess
    private let legacy: KeychainAccess
    private let queue = DispatchQueue(label: "online.nazarovych.transcriber.secrets")
    /// Взводится первым же `errSecMissingEntitlement`: дальше работаем только со старой связкой.
    private var fellBack = false

    public init(modern: KeychainAccess, legacy: KeychainAccess) {
        self.modern = modern
        self.legacy = legacy
        // Перенос из старой связки — разово, лениво (`shared` сам ленивый) и вне главного потока.
        // Очередь последовательная, и этот блок встал в неё первым: любой `get` дождётся переноса
        // и увидит уже перенесённый секрет, а единственный возможный диалог (чтение старого
        // айтема — последний такой диалог в жизни приложения) главный поток не держит.
        queue.async { [self] in
            migrate(Self.apiKeyAccount)
            migrate(Self.codexTokensAccount)
        }
    }

    public func get(_ account: String) -> Data? {
        queue.sync {
            let (status, data) = active.read(account)
            guard fallBack(on: status) else { return data }
            return legacy.read(account).data
        }
    }

    public func set(_ data: Data, account: String) {
        queue.sync {
            let status = active.write(data, account)
            if fallBack(on: status) { _ = legacy.write(data, account) }
        }
    }

    public func delete(_ account: String) {
        queue.sync {
            let status = active.remove(account)
            if fallBack(on: status) { _ = legacy.remove(account) }
        }
    }

    // MARK: - Внутреннее (всё — на `queue`)

    private var active: KeychainAccess { fellBack ? legacy : modern }

    /// `errSecMissingEntitlement` означает одно: приложение подписано без keychain-access-groups.
    /// Переключаемся на старую связку — один раз и с одной строкой в лог.
    private func fallBack(on status: OSStatus) -> Bool {
        guard status == errSecMissingEntitlement, !fellBack else { return false }
        fellBack = true
        FileHandle.standardError.write(Data(
            ("SecretStore: подпись без entitlement keychain-access-groups — "
                + "секреты идут в старую связку ключей (она будет спрашивать пароль).\n").utf8
        ))
        return true
    }

    /// Перенос секрета из старой связки в современную. Best-effort: любая осечка оставляет
    /// всё как было, и пользователь просто переавторизуется в «Настройки → AI».
    private func migrate(_ account: String) {
        let (status, existing) = modern.read(account)
        _ = fallBack(on: status)
        // Нет entitlement — переносить некуда, старая связка и так остаётся рабочей.
        // Спрашиваем именно флаг, а не ответ `fallBack`: тот говорит «переключились прямо
        // сейчас» и для второго аккаунта отвечает `false` — переключение случилось на первом.
        // По этому `false` выполнение шло дальше, к чтению старой связки, то есть к диалогу
        // пароля на каждом запуске неподписанной профилем сборки.
        if fellBack { return }
        guard existing == nil, let data = legacy.read(account).data else { return }
        guard modern.write(data, account) == errSecSuccess else { return }
        _ = legacy.remove(account)
    }
}

// MARK: - Статические обёртки

/// Вызывающим хранилище нужно ровно одно — общее; инъекция связок существует ради тестов.
extension SecretStore {
    public static func get(_ account: String) -> Data? { shared.get(account) }
    public static func set(_ data: Data, account: String) { shared.set(data, account: account) }
    public static func delete(_ account: String) { shared.delete(account) }
    public static func getString(_ account: String) -> String? { shared.getString(account) }
    public static func setString(_ value: String, account: String) {
        shared.setString(value, account: account)
    }
}

extension SecretStore {
    public func getString(_ account: String) -> String? {
        get(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setString(_ value: String, account: String) {
        set(Data(value.utf8), account: account)
    }
}

// MARK: - Связка ключей

/// Операции над одной связкой. Настоящих реализаций две — современная и старая, и отличаются
/// они ровно одним флагом запроса. В тестах подставляется двойник, чтобы настоящие записи
/// пользователя не трогать вовсе.
public struct KeychainAccess: Sendable {
    public var read: @Sendable (String) -> (status: OSStatus, data: Data?)
    public var write: @Sendable (Data, String) -> OSStatus
    public var remove: @Sendable (String) -> OSStatus

    public init(
        read: @escaping @Sendable (String) -> (status: OSStatus, data: Data?),
        write: @escaping @Sendable (Data, String) -> OSStatus,
        remove: @escaping @Sendable (String) -> OSStatus
    ) {
        self.read = read
        self.write = write
        self.remove = remove
    }

    /// Современная связка: айтемы принадлежат группе доступа из entitlement приложения.
    public static let dataProtection = system(dataProtection: true)
    /// Старая file-based связка: там лежат секреты прошлых версий, оттуда мы их забираем.
    public static let legacy = system(dataProtection: false)

    private static let service = "online.nazarovych.transcriber"

    private static func system(dataProtection: Bool) -> KeychainAccess {
        KeychainAccess(
            read: { account in
                var query = baseQuery(account, dataProtection: dataProtection)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                return (status, item as? Data)
            },
            write: { data, account in
                let query = baseQuery(account, dataProtection: dataProtection)
                let status = SecItemUpdate(
                    query as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard status == errSecItemNotFound else { return status }
                var insert = query
                insert[kSecValueData as String] = data
                // Доступ после первой разблокировки: диктовка может стартовать до входа в GUI.
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                return SecItemAdd(insert as CFDictionary, nil)
            },
            remove: { account in
                SecItemDelete(baseQuery(account, dataProtection: dataProtection) as CFDictionary)
            }
        )
    }

    private static func baseQuery(_ account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Единственное отличие двух связок — этот флаг адресует современную.
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }
}
