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

    /// Две диктовки подряд, обе в окно вытеснения: потолок обязан выстоять.
    ///
    /// Регрессия, ради которой тест и написан: вытеснение откладывало саму вставку, и вторая
    /// диктовка попадала в момент, когда стопка выглядела неполной, — обе вставки проходили
    /// «без вытеснения», и карточек становилось шесть.
    func testOverlappingPushesKeepTheCap() async throws {
        let stack = CardStackController()
        for index in 1...5 {
            XCTAssertTrue(stack.push("карточка \(index)"))
        }
        XCTAssertEqual(stack.count, 5)

        // Обе — внутри 240 мс, отведённых на уход вытесненной.
        XCTAssertTrue(stack.push("шестая"))
        XCTAssertTrue(stack.push("седьмая"))
        XCTAssertLessThanOrEqual(stack.count, 5, "учёт не имеет права разъезжаться даже на миг")

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(stack.count, 5, "потолок стопки — пять карточек")
        XCTAssertEqual(cardWindows.count, 5, "и ровно столько же окон на экране")
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
