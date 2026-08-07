import XCTest
@testable import CribeCore

/// Наблюдение за полем. Живой Accessibility здесь не участвует — подставлен двойник:
/// прогон не имеет права читать чужие окна. Проверяется то, из-за чего приём мог бы
/// приписать нам чужие правки.
final class EditWatcherTests: XCTestCase {
    /// Обычный случай: текст вставился и виден в поле — есть от чего отсчитывать.
    func testBaselineIsTakenWhenOurTextIsVisible() {
        XCTAssertEqual(
            EditWatcher.baseline(value: "старое и новый текст", inserted: "новый текст"),
            "старое и новый текст"
        )
    }

    /// Поле не отдало содержимое или вставка уехала не туда: вставленного текста не видно.
    /// Наблюдать нельзя — иначе любая чужая правка была бы записана на наш счёт.
    func testBaselineIsRefusedWhenOurTextIsMissing() {
        XCTAssertNil(EditWatcher.baseline(value: "совсем другое", inserted: "новый текст"))
    }

    /// Пустая вставка «содержится» в любой строке — на этом можно было бы построить
    /// наблюдение за чем угодно. Отказываем явно.
    func testEmptyInsertIsRefused() {
        XCTAssertNil(EditWatcher.baseline(value: "какой-то текст", inserted: "   "))
    }

    /// Полный ход: вставили, человек поправил слово, правка доехала до обработчика.
    func testEditIsNoticedEndToEnd() {
        let field = NSObject()
        let text = LockedText(value: "поправим хероблок сегодня")
        let watcher = EditWatcher(access: FieldAccess(
            focused: { field },
            text: { _ in text.value }
        ))

        let noticed = expectation(description: "правка замечена")
        var got: [Correction] = []
        watcher.watch(inserted: "поправим хероблок сегодня") { corrections in
            got = corrections
            noticed.fulfill()
        }

        // Ждём снимка точки отсчёта, потом «правим» поле и снимаем второй слепок сами:
        // ждать штатные двадцать секунд в прогоне незачем.
        let edited = expectation(description: "поле поправлено")
        DispatchQueue.main.asyncAfter(deadline: .now() + EditWatcher.settleDelay + 0.2) {
            text.value = "поправим heroblock сегодня"
            watcher.collect { corrections in
                got = corrections
                noticed.fulfill()
            }
            edited.fulfill()
        }

        wait(for: [edited], timeout: 3)
        wait(for: [noticed], timeout: 3)
        XCTAssertEqual(got, [Correction(heard: "хероблок", meant: "heroblock")])
    }

    /// Поле не тронули — обработчик не зовётся вовсе. Это самый частый исход, и он обязан
    /// быть тихим: ни правок, ни лишней работы.
    func testUntouchedFieldReportsNothing() {
        let field = NSObject()
        let watcher = EditWatcher(access: FieldAccess(
            focused: { field },
            text: { _ in "поправим хероблок сегодня" }
        ))

        let silent = expectation(description: "обработчик не позван")
        silent.isInverted = true
        watcher.watch(inserted: "поправим хероблок сегодня") { _ in silent.fulfill() }

        DispatchQueue.main.asyncAfter(deadline: .now() + EditWatcher.settleDelay + 0.2) {
            watcher.collect { _ in silent.fulfill() }
        }
        wait(for: [silent], timeout: 2)
    }
}

/// Изменяемый текст поля, к которому обращаются с нескольких очередей.
private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(value: String) { storage = value }

    var value: String {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
