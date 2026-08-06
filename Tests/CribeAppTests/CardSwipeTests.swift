import XCTest
@testable import Cribe

/// Арифметика смахивания. Сам жест проверяется только пальцем (и пробой с синтетическим
/// потоком дельт), а вот пороги, сопротивление и затухание — числа, и они здесь.
final class CardSwipeTests: XCTestCase {

    private let width = CardMetrics.width

    /// Влево карточка идёт след в след: любая задержка тут читается как «залипла».
    func testLeftFollowsTheFingersOneToOne() {
        XCTAssertEqual(CardSwipe.offset(forFingerTravel: -40, width: width), -40)
        XCTAssertEqual(CardSwipe.offset(forFingerTravel: -140, width: width), -140)
    }

    /// Вправо — резина: карточка поддаётся, но всё меньше, и за предел не уходит.
    func testRightIsRubberBanded() {
        let small = CardSwipe.offset(forFingerTravel: 20, width: width)
        let large = CardSwipe.offset(forFingerTravel: 400, width: width)
        XCTAssertGreaterThan(small, 0, "мёртвый край читался бы как поломка")
        XCTAssertLessThan(small, 20, "но и след в след вправо карточка не идёт")
        XCTAssertGreaterThan(large, small, "дальше — всё равно дальше")
        XCTAssertLessThan(large, width * 0.55, "и никогда не дальше упора")
    }

    /// Порог: 35% ширины. Чуть-чуть не дотянули — карточка возвращается.
    func testDismissNeedsThresholdOrFling() {
        let threshold = -width * CardSwipe.dismissFraction
        XCTAssertTrue(CardSwipe.dismisses(offset: threshold, speed: -1, width: width))
        XCTAssertFalse(CardSwipe.dismisses(offset: threshold + 1, speed: -1, width: width))
        // Бросок: короткое, но резкое движение убирает карточку и до порога.
        XCTAssertTrue(CardSwipe.dismisses(offset: -20, speed: -CardSwipe.flingSpeed, width: width))
        XCTAssertFalse(CardSwipe.dismisses(offset: -20, speed: -CardSwipe.flingSpeed + 1, width: width))
    }

    /// Вправо карточка не уходит НИКОГДА: язык всего интерфейса — движение влево.
    func testRightNeverDismisses() {
        XCTAssertFalse(CardSwipe.dismisses(offset: width, speed: 50, width: width))
        XCTAssertFalse(CardSwipe.dismisses(offset: width * 10, speed: 500, width: width))
    }

    /// Затухание — подсказка «отпустишь сейчас, и она уйдёт»: к порогу карточка заметно
    /// бледнеет, но не исчезает совсем, иначе непонятно, что именно уходит.
    func testFadeGrowsOnlyLeftwards() {
        XCTAssertEqual(CardSwipe.opacity(offset: 0, width: width), 1)
        XCTAssertEqual(CardSwipe.opacity(offset: 50, width: width), 1, "вправо не гаснет")
        XCTAssertEqual(
            CardSwipe.opacity(offset: -width * CardSwipe.dismissFraction, width: width),
            Double(CardSwipe.fadeAtThreshold),
            accuracy: 0.001
        )
        XCTAssertEqual(CardSwipe.opacity(offset: -width, width: width), Double(CardSwipe.fadeAtThreshold),
                       accuracy: 0.001, "дальше порога уже не бледнеет")
    }
}
