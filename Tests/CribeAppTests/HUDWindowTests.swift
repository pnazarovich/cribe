import AppKit
import XCTest

@testable import Cribe

/// Окно HUD живёт один показ: прописку во всех пространствах теряет конкретный экземпляр
/// окна, и вернуть её можно только новым. Проверяем, что смена оболочки ничего не роняет —
/// содержимое и место обязаны переехать как есть, иначе пилюля мигнёт пустым кадром.
@MainActor
final class HUDWindowTests: XCTestCase {

    private func makeShell() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
    }

    func testRenewMovesContentsIntoAFreshWindow() {
        let old = makeShell()
        let place = NSRect(x: 40, y: 50, width: 380, height: 92)
        old.setFrame(place, display: false)
        let content = NSView()
        old.contentView = content

        let fresh = HUDWindow.renew(old) { makeShell() }

        XCTAssertFalse(fresh === old, "оболочка обязана быть новой — в этом весь смысл")
        XCTAssertTrue(fresh.contentView === content, "содержимое переезжает, а не строится заново")
        XCTAssertEqual(fresh.frame, place, "место сохраняется: капсула не должна прыгать")
    }

    func testRenewLeavesNothingBehindOnTheOldWindow() {
        let old = makeShell()
        let content = NSView()
        old.contentView = content

        _ = HUDWindow.renew(old) { makeShell() }

        XCTAssertFalse(old.contentView === content, "старая оболочка отпускает содержимое")
        XCTAssertFalse(old.isVisible, "и уходит с экрана")
    }
}
