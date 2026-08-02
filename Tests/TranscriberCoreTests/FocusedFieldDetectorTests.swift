import XCTest
@testable import TranscriberCore

/// Раскладка «ответ AX → вердикт». Живой AX здесь не участвует: прогон не имеет права
/// зависеть ни от разрешения Универсального доступа, ни от того, какое окно сейчас впереди.
final class FocusedFieldDetectorTests: XCTestCase {

    /// Роли настоящих полей ввода — вставка идёт как раньше.
    func testEditableRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
            XCTAssertEqual(
                FocusedFieldDetector.classify(
                    .element(role: role, valueSettable: false, hasSelectedTextRange: false)
                ),
                .editable,
                "роль \(role) должна считаться полем ввода"
            )
        }
    }

    /// Роль ни о чём не говорит, но элемент ведёт себя как поле: веб- и Electron-поля
    /// узнаются именно так — по записываемому значению или по выделению текста.
    func testFieldLikeBehaviourIsEditable() {
        XCTAssertEqual(
            FocusedFieldDetector.classify(
                .element(role: "AXGroup", valueSettable: true, hasSelectedTextRange: false)
            ),
            .editable
        )
        XCTAssertEqual(
            FocusedFieldDetector.classify(
                .element(role: "AXWebArea", valueSettable: false, hasSelectedTextRange: true)
            ),
            .editable
        )
        XCTAssertEqual(
            FocusedFieldDetector.classify(
                .element(role: nil, valueSettable: false, hasSelectedTextRange: true)
            ),
            .editable
        )
    }

    /// Элемент есть, но он не поле и ведёт себя не как поле — вот тут и появляется карточка.
    func testInertElementIsNotEditable() {
        XCTAssertEqual(
            FocusedFieldDetector.classify(
                .element(role: "AXImage", valueSettable: false, hasSelectedTextRange: false)
            ),
            .notEditable
        )
        XCTAssertEqual(
            FocusedFieldDetector.classify(
                .element(role: nil, valueSettable: false, hasSelectedTextRange: false)
            ),
            .notEditable
        )
    }

    /// Фокуса нет вовсе (рабочий стол, окно без полей) — вставлять некуда.
    func testNoFocusIsNotEditable() {
        XCTAssertEqual(FocusedFieldDetector.classify(.noFocus), .notEditable)
    }

    /// Главное правило детектора: молчание системы — не приговор. Нет разрешения, зависло
    /// приложение, отвалился AX — вставляем как раньше, а не прячем текст в карточку.
    func testUnavailableIsUnknown() {
        XCTAssertEqual(FocusedFieldDetector.classify(.unavailable), .unknown)
    }
}
