import XCTest
@testable import CribeCore

/// Переезд данных из-под старого имени продукта. Всё на временных папках и временных
/// доменах настроек: настоящие `~/Library/Application Support/Transcriber` и домен владельца
/// тесты не открывают ни разу.
final class LegacyRenameTests: XCTestCase {
    private var base: URL!
    private var old: URL!
    private var new: URL!
    private var oldDomain: String!
    private var newDomain: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LegacyRenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        old = base.appendingPathComponent("Transcriber", isDirectory: true)
        new = base.appendingPathComponent("Cribe", isDirectory: true)

        oldDomain = "tests.legacyrename.old.\(UUID().uuidString)"
        newDomain = "tests.legacyrename.new.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: newDomain))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: oldDomain)
        defaults.removePersistentDomain(forName: newDomain)
    }

    // MARK: - Папка данных

    /// Главный случай: 4,5 ГБ моделей и словарь остаются на месте, просто под новым именем.
    func testMovesOldFolderWithItsContents() throws {
        try makeFolder(old, file: "models/big.mlmodelc", text: "модель")

        XCTAssertTrue(LegacyRename.migrateFolder(from: old, to: new))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("models/big.mlmodelc")), "модель")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    /// Второй запуск: старой папки уже нет — переезжать нечему, и это не ошибка.
    func testDoesNothingWithoutOldFolder() {
        XCTAssertFalse(LegacyRename.migrateFolder(from: old, to: new))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }

    /// Новая папка уже завелась (приложение успело поработать) — старую не вливаем и не трогаем.
    func testKeepsNewFolderWhenBothExist() throws {
        try makeFolder(old, file: "dictionary.json", text: "старый")
        try makeFolder(new, file: "dictionary.json", text: "новый")

        XCTAssertFalse(LegacyRename.migrateFolder(from: old, to: new))
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("dictionary.json")), "новый")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("dictionary.json")), "старый")
    }

    // MARK: - Настройки

    /// Хоткеи, язык и микрофон переезжают в домен нового имени, старый домен исчезает.
    func testCopiesValuesFromOldDomain() {
        defaults.setPersistentDomain(["language": "uk", "keptRecordings": 5], forName: oldDomain)

        XCTAssertTrue(LegacyRename.migrateDefaults(from: oldDomain, into: defaults))
        XCTAssertEqual(defaults.string(forKey: "language"), "uk")
        XCTAssertEqual(defaults.integer(forKey: "keptRecordings"), 5)
        XCTAssertNil(defaults.persistentDomain(forName: oldDomain))
    }

    /// Значение, уже записанное под новым именем, старое не перебивает.
    func testKeepsExistingValue() {
        defaults.setPersistentDomain(["language": "uk"], forName: oldDomain)
        defaults.set("en", forKey: "language")

        XCTAssertTrue(LegacyRename.migrateDefaults(from: oldDomain, into: defaults))
        XCTAssertEqual(defaults.string(forKey: "language"), "en")
    }

    /// Старого домена нет — ничего не происходит (в том числе на втором запуске).
    func testDoesNothingWithoutOldDomain() {
        XCTAssertFalse(LegacyRename.migrateDefaults(from: oldDomain, into: defaults))
        XCTAssertNil(defaults.string(forKey: "language"))
    }

    // MARK: - Вспомогательное

    private func makeFolder(_ folder: URL, file: String, text: String) throws {
        let target = folder.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: target, atomically: true, encoding: .utf8)
    }
}
