import XCTest
@testable import Cribe

/// Esc во время записи забирается целиком и в приложение не уходит.
///
/// Раньше тап был только слушающим: Esc отменял диктовку и вдобавок доходил до
/// фронтмост-приложения. Диктуя в Claude Code и передумав, человек вместе с диктовкой
/// останавливал работу Claude Code.
final class EscapeGateTests: XCTestCase {

    private let none = EscapeGate.Verdict(swallow: false, cancel: false, removeTap: false)

    /// Нажатие отменяет диктовку и не доходит до приложения, отпускание — тоже не доходит.
    func testEscapePressIsSwallowedWholeAndCancelsOnce() {
        var gate = EscapeGate()
        XCTAssertEqual(gate.decide(isDown: true, isEscape: true, isRepeat: false),
                       .init(swallow: true, cancel: true, removeTap: false))
        XCTAssertEqual(gate.decide(isDown: false, isEscape: true, isRepeat: false),
                       .init(swallow: true, cancel: false, removeTap: false))
        XCTAssertFalse(gate.pressInFlight)
    }

    /// Удержание даёт автоповтор — он съедается, но отмену второй раз не зовёт.
    func testAutorepeatIsSwallowedWithoutCancellingAgain() {
        var gate = EscapeGate()
        _ = gate.decide(isDown: true, isEscape: true, isRepeat: false)
        for _ in 0..<5 {
            XCTAssertEqual(gate.decide(isDown: true, isEscape: true, isRepeat: true),
                           .init(swallow: true, cancel: false, removeTap: false))
        }
    }

    /// Всё, что не Esc, проходит нетронутым — диктовке не мешают ни буквы, ни Enter.
    func testOtherKeysPassThrough() {
        var gate = EscapeGate()
        XCTAssertEqual(gate.decide(isDown: true, isEscape: false, isRepeat: false), none)
        XCTAssertEqual(gate.decide(isDown: false, isEscape: false, isRepeat: false), none)
    }

    /// Отпускание без своего нажатия — не наше: Esc зажали ещё до того, как встал тап,
    /// и его нажатие приложение уже получило. Съесть отпускание значило бы оставить
    /// приложение с «зажатой» клавишей.
    func testForeignReleasePassesThrough() {
        var gate = EscapeGate()
        XCTAssertEqual(gate.decide(isDown: false, isEscape: true, isRepeat: false), none)
    }

    /// Запись гаснет на нажатии, и тап просят снять, пока Esc ещё зажат. Снимается он на
    /// отпускании — иначе отпускание ушло бы в приложение.
    func testTapIsRemovedOnReleaseWhenStopWasRequestedMidPress() {
        var gate = EscapeGate()
        _ = gate.decide(isDown: true, isEscape: true, isRepeat: false)
        gate.stopRequested = true
        XCTAssertEqual(gate.decide(isDown: false, isEscape: true, isRepeat: false),
                       .init(swallow: true, cancel: false, removeTap: true))
    }
}
