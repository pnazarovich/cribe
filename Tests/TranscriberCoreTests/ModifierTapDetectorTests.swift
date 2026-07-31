import XCTest
@testable import TranscriberCore

/// Тап по правому ⌘ должен срабатывать только вхолостую: ⌘-аккорды пользователя
/// живут своей жизнью и диктовку не запускают.
final class ModifierTapDetectorTests: XCTestCase {

    private let rcmd = ModifierTapDetector.rightCommandKeyCode
    private let rcmdDown = ModifierTapDetector.rightCommandFlag
    private let released: UInt64 = 0

    func testPressAndReleaseFires() {
        var detector = ModifierTapDetector()
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0))
        XCTAssertTrue(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }

    /// ⌘C правым ⌘: между нажатием и отпусканием была клавиша — это аккорд.
    func testKeyDownBetweenCancels() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        detector.keyDown()
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }

    /// ⇧⌘ и подобное: смена другого модификатора во время удержания отменяет тап.
    func testOtherModifierCancels() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        _ = detector.flagsChanged(keyCode: 56, flags: rcmdDown | 0x2, at: 0.05)
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }

    func testLongHoldDoesNotFire() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        XCTAssertFalse(
            detector.flagsChanged(keyCode: rcmd, flags: released, at: ModifierTapDetector.holdLimit + 0.01)
        )
    }

    /// Левый ⌘ шлёт свой keyCode: удержание левого не должно выглядеть тапом правого.
    func testLeftCommandIgnored() {
        var detector = ModifierTapDetector()
        XCTAssertFalse(detector.flagsChanged(keyCode: 55, flags: 0x8, at: 0))
        XCTAssertFalse(detector.flagsChanged(keyCode: 55, flags: released, at: 0.1))
    }

    /// Отпускание правого ⌘ при всё ещё зажатом левом: device-бит правого погас — это отпускание.
    func testReleaseWhileLeftCommandHeld() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown | 0x8, at: 0)
        XCTAssertTrue(detector.flagsChanged(keyCode: rcmd, flags: 0x8, at: 0.1))
    }

    /// После сброса (тап отключали и включали) ожидание не воскресает.
    func testResetDropsPendingTap() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        detector.reset()
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }
}
