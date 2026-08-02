import XCTest
@testable import TranscriberCore

/// Раскладка «ответ AX → вердикт». Живой AX здесь не участвует: прогон не имеет права
/// зависеть ни от разрешения Универсального доступа, ни от того, какое окно сейчас впереди.
final class FocusedFieldDetectorTests: XCTestCase {

    private func state(
        role: String?,
        settable: Bool = false,
        range: Bool = false,
        web: Bool = false
    ) -> FocusState {
        FocusedFieldDetector.classify(
            .element(role: role, valueSettable: settable, hasSelectedTextRange: range, isWebContext: web)
        ).state
    }

    /// Роли настоящих полей ввода — вставка идёт как раньше.
    func testEditableRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
            XCTAssertEqual(state(role: role), .editable, "роль \(role) должна считаться полем ввода")
        }
    }

    /// Записываемое значение — признак настоящего поля и у нативных вью, и у Electron-композеров
    /// (замерено: Telegram, cmux, Claude — везде AXTextArea с settable-значением).
    func testSettableValueIsEditable() {
        XCTAssertEqual(state(role: "AXGroup", settable: true), .editable)
    }

    /// Роли нет вовсе, но элемент отдаёт выделение текстом — нативное поле без роли.
    func testUnnamedRoleWithSelectedTextRangeIsEditable() {
        XCTAssertEqual(state(role: nil, range: true), .editable)
    }

    /// Главная поломка этого раунда. Chrome отдаёт `AXSelectedTextRange` из ЛЮБОГО узла
    /// страницы — из веб-области, из группы, даже из кнопки. Раньше это означало «поле есть»,
    /// и диктовка вслепую летела в страницу вместо карточки.
    func testWebContainersAreNotTreatedAsFieldsByRangeAlone() {
        XCTAssertNotEqual(state(role: "AXWebArea", range: true, web: true), .editable)
        XCTAssertNotEqual(state(role: "AXGroup", range: true, web: true), .editable)
        XCTAssertNotEqual(state(role: "AXButton", range: true, web: true), .editable)
    }

    /// Но и карточку веб-контенту не назначаем: замерено, что Chrome отдаёт одно и то же
    /// с курсором в поле и без него, — значит, отличить нечем, и это честное «не знаю»,
    /// которое по правилу смещения вставляется как раньше.
    func testWebContextIsUnknownNotNotEditable() {
        XCTAssertEqual(state(role: "AXWebArea", range: true, web: true), .unknown)
        XCTAssertEqual(state(role: "AXButton", range: true, web: true), .unknown)
    }

    /// Настоящее поле внутри веба узнаётся ролью и остаётся полем: разрешившееся
    /// AX-дерево (Safari, разогретый Chrome) не должно получать карточку вместо вставки.
    func testWebTextFieldStaysEditable() {
        XCTAssertEqual(state(role: "AXTextField", range: true, web: true), .editable)
        XCTAssertEqual(state(role: "AXTextArea", settable: true, range: true, web: true), .editable)
    }

    /// Нативный элемент, который не поле и ведёт себя не как поле — вот тут и появляется карточка.
    func testInertElementIsNotEditable() {
        XCTAssertEqual(state(role: "AXImage"), .notEditable)
        XCTAssertEqual(state(role: "AXWindow"), .notEditable)
        XCTAssertEqual(state(role: "AXOutline"), .notEditable)
        XCTAssertEqual(state(role: nil), .notEditable)
    }

    /// Фокуса нет вовсе (рабочий стол, полноэкранное окно без полей) — вставлять некуда.
    func testNoFocusIsNotEditable() {
        XCTAssertEqual(FocusedFieldDetector.classify(.noFocus).state, .notEditable)
    }

    /// Главное правило детектора: молчание системы — не приговор. Нет разрешения, зависло
    /// приложение, отвалился AX — вставляем как раньше, а не прячем текст в карточку.
    func testUnavailableIsUnknown() {
        XCTAssertEqual(FocusedFieldDetector.classify(.unavailable).state, .unknown)
    }

    /// Роль едет в вердикт: без неё полевой отчёт «карточка не появилась» разобрать нечем.
    func testVerdictCarriesRoleForLogging() {
        let verdict = FocusedFieldDetector.classify(
            .element(role: "AXWebArea", valueSettable: false, hasSelectedTextRange: true, isWebContext: true)
        )
        XCTAssertEqual(verdict.role, "AXWebArea")
    }
}
