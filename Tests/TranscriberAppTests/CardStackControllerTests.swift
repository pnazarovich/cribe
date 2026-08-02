import AppKit
import XCTest
@testable import Transcriber

/// Стопка карточек: она держит настоящие окна, поэтому и проверяется по окнам.
@MainActor
final class CardStackControllerTests: XCTestCase {

    /// Окна карточек среди окон приложения. Чужие окна прогона (их заводит XCTest)
    /// в счёт не идут — считаем только те, что размером с карточку.
    private var cardWindows: [NSWindow] {
        NSApplication.shared.windows.filter {
            $0.isVisible && abs($0.frame.width - (CardMetrics.width + CardMetrics.bleed * 2)) < 1
        }
    }

    override func tearDown() async throws {
        for window in cardWindows { window.orderOut(nil) }
    }

    /// Стопка не растёт выше потолка, а вытесненная карточка ЗАБИРАЕТ СВОЁ ОКНО С ЭКРАНА.
    ///
    /// Регрессия, ради которой тест и написан: `cards.removeLast().dismiss()` выбрасывал
    /// последнюю сильную ссылку на карточку, задача закрытия просыпалась со слабым `self`
    /// в пустоту — и окно, которое держит список окон приложения, оставалось висеть навсегда.
    func testEvictedCardReleasesItsWindow() async throws {
        let stack = CardStackController()
        for index in 1...5 {
            XCTAssertTrue(stack.push("карточка \(index)"))
        }
        XCTAssertEqual(stack.count, 5)
        XCTAssertEqual(cardWindows.count, 5, "пять карточек — пять окон")

        // Шестая вытесняет самую старую.
        XCTAssertTrue(stack.push("карточка 6"))
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertEqual(stack.count, 5, "потолок стопки — пять карточек")
        XCTAssertEqual(cardWindows.count, 5, "вытесненная карточка обязана убрать своё окно")
    }

    /// Обычный уход карточки тоже освобождает окно — тот же путь, но со ссылкой в стопке.
    func testDismissedCardReleasesItsWindow() async throws {
        let stack = CardStackController()
        XCTAssertTrue(stack.push("одна карточка"))
        XCTAssertEqual(cardWindows.count, 1)

        stack.dismissAllForTesting()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(stack.count, 0)
        XCTAssertEqual(cardWindows.count, 0)
    }
}
