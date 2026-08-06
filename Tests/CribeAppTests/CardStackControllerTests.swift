import AppKit
import XCTest
@testable import Cribe

/// Стопка карточек: она держит настоящие окна, поэтому и проверяется по окнам.
@MainActor
final class CardStackControllerTests: XCTestCase {

    /// Экран заведомо высокий: проверяем потолок в карточках, а не «сколько влезло».
    /// Без подставного экрана исход зависел бы от монитора машины, где идёт прогон.
    private static let tallScreen = CGRect(x: 0, y: 0, width: 1512, height: 4000)

    private func makeStack(screen: CGRect = tallScreen) -> CardStackController {
        CardStackController(screenProvider: { screen })
    }

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
        let stack = makeStack()
        for index in 1...10 {
            XCTAssertTrue(stack.push("карточка \(index)"))
        }
        XCTAssertEqual(stack.count, 10)
        XCTAssertEqual(cardWindows.count, 10, "десять карточек — десять окон")

        // Одиннадцатая вытесняет самую старую.
        XCTAssertTrue(stack.push("карточка 11"))
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertEqual(stack.count, 10, "потолок стопки — десять карточек")
        XCTAssertEqual(cardWindows.count, 10, "вытесненная карточка обязана убрать своё окно")
    }

    /// Две диктовки подряд, обе в окно вытеснения: потолок обязан выстоять.
    ///
    /// Регрессия, ради которой тест и написан: вытеснение откладывало саму вставку, и вторая
    /// диктовка попадала в момент, когда стопка выглядела неполной, — обе вставки проходили
    /// «без вытеснения», и стопка перерастала предел.
    func testOverlappingPushesKeepTheCap() async throws {
        let stack = makeStack()
        for index in 1...10 {
            XCTAssertTrue(stack.push("карточка \(index)"))
        }
        XCTAssertEqual(stack.count, 10)

        // Обе — внутри 240 мс, отведённых на уход вытесненной.
        XCTAssertTrue(stack.push("одиннадцатая"))
        XCTAssertTrue(stack.push("двенадцатая"))
        XCTAssertLessThanOrEqual(stack.count, 10, "учёт не имеет права разъезжаться даже на миг")

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(stack.count, 10, "потолок стопки — десять карточек")
        XCTAssertEqual(cardWindows.count, 10, "и ровно столько же окон на экране")
    }

    /// На низком экране предел не в штуках, а в высоте: стопка перестаёт расти раньше десяти
    /// и целиком помещается на экране — карточки не имеют права уезжать за верхний край.
    func testLowScreenCapsStackByHeight() async throws {
        // Высоты хватает на две-три однострочные карточки, но никак не на десять.
        let stack = makeStack(screen: CGRect(x: 0, y: 0, width: 1512, height: 300))
        for index in 1...10 {
            XCTAssertTrue(stack.push("карточка \(index)"))
        }
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertTrue(stack.fitsOnScreen, "стопка обязана помещаться в высоту экрана")
        XCTAssertLessThanOrEqual(stack.stackedHeight, 300)
        XCTAssertLessThan(stack.count, 10, "низкий экран ограничивает стопку раньше потолка")
        // На 300 pt влезает около трёх однострочных карточек: если вдруг осталась одна,
        // это уже не «сколько влезает», а поломка расчёта высоты.
        XCTAssertGreaterThanOrEqual(stack.count, 2, "высота считается, а не отсекается наугад")
        XCTAssertEqual(cardWindows.count, stack.count, "лишние окна должны были уйти с экрана")
    }

    /// Экран ниже одной карточки — вырожденный случай: показать её всё равно лучше,
    /// чем не показать ничего, поэтому последнюю карточку не вытесняем никогда.
    func testSingleCardSurvivesEvenOnAnImpossiblyShortScreen() {
        let stack = makeStack(screen: CGRect(x: 0, y: 0, width: 1512, height: 10))
        XCTAssertTrue(stack.push("одна карточка"))
        XCTAssertEqual(stack.count, 1)
    }

    /// Обычный уход карточки тоже освобождает окно — тот же путь, но со ссылкой в стопке.
    func testDismissedCardReleasesItsWindow() async throws {
        let stack = makeStack()
        XCTAssertTrue(stack.push("одна карточка"))
        XCTAssertEqual(cardWindows.count, 1)

        stack.dismissAllForTesting()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(stack.count, 0)
        XCTAssertEqual(cardWindows.count, 0)
    }
}
