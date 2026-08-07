import XCTest
@testable import Cribe

/// Подпись в шапке карточки. Карточки копятся стопкой и приезжают из разных программ —
/// имя программы и есть единственное, что их различает.
@MainActor
final class CardSourceTests: XCTestCase {
    /// Программа известна — её имя и стоит в шапке.
    func testSourceAppIsRemembered() {
        XCTAssertEqual(CardModel(text: "текст", source: "Telegram").source, "Telegram")
    }

    /// Система не ответила: подписи взяться неоткуда, и карточка остаётся безымянной —
    /// решение о запасном имени принимает вью, а не модель.
    func testUnknownSourceStaysNil() {
        XCTAssertNil(CardModel(text: "текст").source)
    }
}
