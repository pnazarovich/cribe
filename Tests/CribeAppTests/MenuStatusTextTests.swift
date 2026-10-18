import XCTest
@testable import Cribe
@testable import CribeCore

/// Строка состояния в меню.
final class MenuStatusTextTests: XCTestCase {

    /// Отмечено несколько языков — строка называет все, в порядке меню.
    func testIdleNamesAllEnabledLanguages() {
        XCTAssertEqual(
            MenuStatusText.line(state: .idle, languages: [.uk, .ru], translating: false),
            "Готов · Русский + Українська"
        )
    }

    /// Цель перевода — кодом выбранного языка. В 0.4.1 здесь было вписано «→ EN», и строка
    /// врала, когда диктовка уходила на польский.
    func testRecordingShowsTheRealTranslationTarget() {
        let line = MenuStatusText.line(
            state: .recording(live: "", level: 0), languages: [.ru], translating: true, target: .pl
        )
        XCTAssertTrue(line.hasSuffix("→ PL"), line)
    }
}
