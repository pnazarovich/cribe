import XCTest
@testable import Cribe

/// Автосохранение ключа OpenAI. Тесты существуют из-за живой жалобы «при каждом
/// перезапуске снова просят ключ»: сохранение висело только на кнопке, человек вводил
/// ключ и закрывал окно — в связку не попадало ничего.
final class APIKeyFieldTests: XCTestCase {
    /// Ключ ввели в пустое поле — это и есть тот случай, ради которого всё затевалось.
    func testTypedKeyIsSaved() {
        XCTAssertTrue(APIKeyField.changed(typed: "sk-новый", stored: ""))
    }

    /// Окно открыли и закрыли, ничего не трогая: писать в связку незачем.
    func testUntouchedKeyIsNotRewritten() {
        XCTAssertFalse(APIKeyField.changed(typed: "sk-старый", stored: "sk-старый"))
    }

    /// Поле очистили намеренно — это «удалить ключ», и такое сохранять надо.
    func testClearedKeyCountsAsChange() {
        XCTAssertTrue(APIKeyField.changed(typed: "", stored: "sk-старый"))
    }

    /// Связка не отдала ключ: поле пустое, и прочитанное пустое. Закрытие окна не имеет
    /// права превратиться в удаление живого ключа — это была бы потеря данных на ровном месте.
    func testFailedReadDoesNotWipeTheKey() {
        XCTAssertFalse(APIKeyField.changed(typed: "", stored: ""))
    }

    /// Пробелы по краям правкой не считаются: ключ и так сохраняется обрезанным.
    func testWhitespaceIsNotAnEdit() {
        XCTAssertFalse(APIKeyField.changed(typed: "  sk-старый \n", stored: "sk-старый"))
    }
}
