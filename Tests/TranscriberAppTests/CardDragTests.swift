import AppKit
import XCTest
@testable import Transcriber

/// Перетаскивание карточки в чужое поле ввода.
///
/// Регрессия, ради которой тесты и написаны: сброс в поле сообщения Telegram срабатывал
/// через раз. Наши окна стоят на ярусе `.statusBar` — ВЫШЕ окна-приёмника — и в нижнем
/// левом углу экрана, ровно там, где у мессенджера поле ввода. Карточка, накрывшая точку
/// сброса, забирала сброс себе, а принять его не могла: дропы мы нигде не регистрируем.
/// Отсюда инвариант: пока идёт жест, ни одно окно стопки не ловит мышь.
@MainActor
final class CardDragTests: XCTestCase {

    private static let tallScreen = CGRect(x: 0, y: 0, width: 1512, height: 4000)

    private func makeStack() -> CardStackController {
        CardStackController(screenProvider: { Self.tallScreen })
    }

    /// Окна карточек среди окон приложения — по ширине, как и в тестах стопки: чужие окна
    /// прогона заводит XCTest, и они в счёт не идут.
    private var cardWindows: [NSWindow] {
        NSApplication.shared.windows.filter {
            $0.isVisible && abs($0.frame.width - (CardMetrics.width + CardMetrics.bleed * 2)) < 1
        }
    }

    override func tearDown() async throws {
        for window in cardWindows { window.orderOut(nil) }
    }

    /// Тащат одну карточку — сквозными становятся ВСЕ окна стопки, включая соседние:
    /// точку сброса накрывает любая из них, а не только та, что под курсором.
    func testDragMakesEveryCardWindowTransparentToTheDrop() throws {
        let stack = makeStack()
        for index in 1...3 { XCTAssertTrue(stack.push("карточка \(index)")) }
        XCTAssertEqual(cardWindows.count, 3)
        XCTAssertTrue(
            cardWindows.allSatisfy { !$0.ignoresMouseEvents },
            "в покое карточки обязаны ловить мышь — иначе не нажать ни одной кнопки"
        )

        let card = try XCTUnwrap(stack.topCardForTesting)
        card.dragBeganForTesting()

        XCTAssertTrue(stack.isDragInProgress)
        XCTAssertTrue(
            cardWindows.allSatisfy { $0.ignoresMouseEvents },
            "на время жеста ни одно наше окно не имеет права стоять между курсором и приёмником"
        )
    }

    /// Жест кончился — карточки снова живые. Отказ приёмника оставляет их на экране,
    /// и мёртвая стопка была бы хуже несработавшего сброса.
    func testDropRefusalRestoresInteractivity() throws {
        let stack = makeStack()
        for index in 1...3 { XCTAssertTrue(stack.push("карточка \(index)")) }

        let card = try XCTUnwrap(stack.topCardForTesting)
        card.dragBeganForTesting()
        card.dragEndedForTesting(accepted: false)

        XCTAssertFalse(stack.isDragInProgress)
        XCTAssertEqual(cardWindows.count, 3, "отказ приёмника карточку не убирает")
        XCTAssertTrue(cardWindows.allSatisfy { !$0.ignoresMouseEvents })
    }

    /// Диктовка, доехавшая посреди жеста, не имеет права проломить инвариант: новая
    /// карточка приезжает в самый низ экрана — то есть прямо в точку сброса.
    func testCardArrivingMidDragIsTransparentToo() throws {
        let stack = makeStack()
        XCTAssertTrue(stack.push("первая"))

        let card = try XCTUnwrap(stack.topCardForTesting)
        card.dragBeganForTesting()
        XCTAssertTrue(stack.push("приехала посреди жеста"))

        XCTAssertTrue(
            cardWindows.allSatisfy { $0.ignoresMouseEvents },
            "новая карточка обязана встать в стопку такой же сквозной, как и остальные"
        )
    }

    /// Пустой текст перетаскиванием не отправляем: приёмник такой сброс отклоняет, и
    /// жест выглядит сорвавшимся ровно так же, как и перекрытое окно.
    func testBlankTextNeverBecomesADragPayload() {
        XCTAssertNil(CardPanel.dragPayload(nil))
        XCTAssertNil(CardPanel.dragPayload(""))
        XCTAssertNil(CardPanel.dragPayload("   \n\t "))
        XCTAssertEqual(CardPanel.dragPayload("привет"), "привет")
        // Текст отдаётся КАК ЕСТЬ: обрезка нужна только на проверку пустоты.
        XCTAssertEqual(CardPanel.dragPayload(" привет "), " привет ")
    }
}
