import XCTest
@testable import Cribe

/// Что панель пишет, пока модель поднимается. Обычно это две секунды, но первая загрузка
/// после обновления приложения занимает минуты: CoreML заново компилирует модель под
/// Neural Engine. Замерено на живом запуске — 121,9 с против 2,4 с на прогретом кэше.
/// Без объяснения такое ожидание читается как зависание, о чём и сообщали.
final class PreparingTextTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    private func text(after seconds: TimeInterval) -> String {
        PanelPill.preparingText(since: start, now: start.addingTimeInterval(seconds))
    }

    /// Обычная загрузка: только секундомер, пугать словами не за что.
    func testShortPreparationStaysQuiet() {
        XCTAssertFalse(text(after: 3).contains("обновления"))
    }

    /// Ожидание затянулось — человек имеет право знать, почему и что это разово.
    func testLongPreparationExplainsItself() {
        XCTAssertTrue(text(after: 40).contains("разовая подготовка после обновления"))
    }

    /// Секундомер идёт в обоих случаях: он и есть доказательство, что работа идёт.
    func testTimerIsAlwaysShown() {
        XCTAssertTrue(text(after: 3).contains("0:03"))
        XCTAssertTrue(text(after: 95).contains("1:35"))
    }
}
