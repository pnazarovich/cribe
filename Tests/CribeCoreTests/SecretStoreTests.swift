import XCTest
@testable import CribeCore

/// Хранилище секретов. Обе связки — двойники в памяти: настоящую связку ключей тесты
/// не открывают ни разу, поэтому и диалогов, и чужих записей здесь быть не может.
final class SecretStoreTests: XCTestCase {
    private var modern: FakeKeychain!
    private var legacy: FakeKeychain!

    override func setUpWithError() throws {
        modern = FakeKeychain()
        legacy = FakeKeychain()
    }

    private func makeStore() -> SecretStore {
        SecretStore(modern: modern.access, legacy: legacy.access)
    }

    // MARK: - Обычная работа

    func testRoundTripsThroughModernKeychain() {
        let store = makeStore()
        store.setString("sk-test-123", account: SecretStore.apiKeyAccount)

        XCTAssertEqual(store.getString(SecretStore.apiKeyAccount), "sk-test-123")
        XCTAssertEqual(modern.items[SecretStore.apiKeyAccount], Data("sk-test-123".utf8))
        XCTAssertTrue(legacy.items.isEmpty)
    }

    func testOverwriteReplacesValue() {
        let store = makeStore()
        store.setString("first", account: "a")
        store.setString("second", account: "a")

        XCTAssertEqual(store.getString("a"), "second")
    }

    func testDeleteRemovesOnlyRequestedAccount() {
        let store = makeStore()
        store.setString("key", account: SecretStore.apiKeyAccount)
        store.setString("tokens", account: SecretStore.codexTokensAccount)

        store.delete(SecretStore.apiKeyAccount)

        XCTAssertNil(store.get(SecretStore.apiKeyAccount))
        XCTAssertEqual(store.getString(SecretStore.codexTokensAccount), "tokens")
    }

    func testMissingAccountReadsAsNil() {
        XCTAssertNil(makeStore().get("nothing-here"))
    }

    // MARK: - Перенос из старой связки

    func testImportsLegacySecretOnFirstAccessAndClearsIt() {
        legacy.items[SecretStore.codexTokensAccount] = Data("tokens".utf8)
        let store = makeStore()

        XCTAssertEqual(store.getString(SecretStore.codexTokensAccount), "tokens")
        XCTAssertEqual(modern.items[SecretStore.codexTokensAccount], Data("tokens".utf8))
        XCTAssertNil(legacy.items[SecretStore.codexTokensAccount])
        XCTAssertEqual(legacy.removed, [SecretStore.codexTokensAccount])
    }

    func testModernValueWinsAndLegacyIsLeftAlone() {
        modern.items[SecretStore.apiKeyAccount] = Data("from-modern".utf8)
        legacy.items[SecretStore.apiKeyAccount] = Data("from-legacy".utf8)
        let store = makeStore()

        XCTAssertEqual(store.getString(SecretStore.apiKeyAccount), "from-modern")
        XCTAssertEqual(legacy.items[SecretStore.apiKeyAccount], Data("from-legacy".utf8))
        XCTAssertTrue(legacy.removed.isEmpty)
    }

    func testLegacyIsKeptWhenTransferFails() {
        // Запись в современную связку не удалась — оригинал в старой обязан остаться.
        legacy.items[SecretStore.apiKeyAccount] = Data("tokens".utf8)
        modern.writeStatus = errSecIO
        let store = makeStore()

        XCTAssertEqual(legacy.items[SecretStore.apiKeyAccount], Data("tokens".utf8))
        XCTAssertTrue(legacy.removed.isEmpty)
        XCTAssertNil(store.get(SecretStore.apiKeyAccount))
    }

    func testFailedReadOfLegacyIsSilent() {
        // Пользователь отказал в доступе к старой связке — просто работаем дальше без секрета.
        legacy.items[SecretStore.apiKeyAccount] = Data("tokens".utf8)
        legacy.readStatus = errSecAuthFailed
        let store = makeStore()

        XCTAssertNil(store.get(SecretStore.apiKeyAccount))
        XCTAssertTrue(modern.items.isEmpty)
    }

    // MARK: - Подпись без entitlement

    func testFallsBackToLegacyWhenEntitlementIsMissing() {
        modern.failure = errSecMissingEntitlement
        legacy.items[SecretStore.apiKeyAccount] = Data("from-legacy".utf8)
        let store = makeStore()

        XCTAssertEqual(store.getString(SecretStore.apiKeyAccount), "from-legacy")
        // Перенос при этом не тронул старую связку: переносить некуда.
        XCTAssertTrue(legacy.removed.isEmpty)
    }

    func testWritesAndDeletesGoToLegacyWhenEntitlementIsMissing() {
        modern.failure = errSecMissingEntitlement
        let store = makeStore()

        store.setString("key", account: SecretStore.apiKeyAccount)
        XCTAssertEqual(legacy.items[SecretStore.apiKeyAccount], Data("key".utf8))
        XCTAssertEqual(store.getString(SecretStore.apiKeyAccount), "key")

        store.delete(SecretStore.apiKeyAccount)
        XCTAssertNil(legacy.items[SecretStore.apiKeyAccount])
    }

    func testMigrationLeavesLegacyUntouchedWhenEntitlementIsMissing() {
        modern.failure = errSecMissingEntitlement
        legacy.items[SecretStore.codexTokensAccount] = Data("tokens".utf8)
        let store = makeStore()

        // Барьер: синхронный вызов встаёт на очереди хранилища за перенос и дожидается его.
        _ = store.get(SecretStore.apiKeyAccount)

        XCTAssertEqual(
            legacy.reads, [SecretStore.apiKeyAccount],
            "перенос не должен читать старую связку: без entitlement переносить некуда, "
                + "а каждое такое чтение — диалог пароля"
        )
    }

    func testModernKeychainIsNotRetriedAfterFallback() {
        modern.failure = errSecMissingEntitlement
        let store = makeStore()

        _ = store.get(SecretStore.apiKeyAccount)
        let afterFirstRead = modern.calls
        _ = store.get(SecretStore.apiKeyAccount)
        store.setString("key", account: SecretStore.apiKeyAccount)
        store.delete(SecretStore.apiKeyAccount)

        XCTAssertEqual(modern.calls, afterFirstRead, "в современную связку больше не стучимся")
    }
}

/// Связка-двойник: словарь в памяти, счётчик обращений и подменный статус ошибки.
/// Обращаются к нему с очереди хранилища, поэтому всё под замком.
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var removedAccounts: [String] = []
    private var readAccounts: [String] = []
    private var callCount = 0

    /// Статус, который связка возвращает на любую операцию (нет entitlement, например).
    var failure: OSStatus?
    /// Точечные отказы: только на чтении / только на записи.
    var readStatus: OSStatus?
    var writeStatus: OSStatus?

    var items: [String: Data] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    var removed: [String] { lock.withLock { removedAccounts } }
    var reads: [String] { lock.withLock { readAccounts } }
    var calls: Int { lock.withLock { callCount } }

    var access: KeychainAccess {
        KeychainAccess(
            read: { [self] account in
                lock.withLock {
                    callCount += 1
                    readAccounts.append(account)
                }
                if let status = failure ?? readStatus { return (status, nil) }
                guard let data = items[account] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            },
            write: { [self] data, account in
                lock.withLock { callCount += 1 }
                if let status = failure ?? writeStatus { return status }
                items[account] = data
                return errSecSuccess
            },
            remove: { [self] account in
                lock.withLock { callCount += 1 }
                if let status = failure { return status }
                lock.withLock {
                    removedAccounts.append(account)
                    storage[account] = nil
                }
                return errSecSuccess
            }
        )
    }
}
