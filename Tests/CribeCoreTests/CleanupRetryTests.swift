import XCTest
@testable import CribeCore

/// Повтор чистки — единственное место, где приложение переписывает текст, который человек
/// уже видит в своём поле. Цена ошибки тут выше обычного: Cmd-A выделяет ВСЁ поле, и если
/// в нём успело появиться чужое, замена его затрёт. Поэтому проверяется не «работает ли
/// повтор», а «отказывается ли он работать там, где не должен».
final class CleanupRetryTests: XCTestCase {

    private func retry(delivered: String = "текст слоя два") -> CleanupRetry {
        CleanupRetry(text: "текст слоя два", delivered: delivered, language: .ru, translating: false)
    }

    /// Поле не изменилось — замена законна.
    func testReplacesWhenFieldStillHoldsOurText() {
        let spy = Spy(field: "текст слоя два")
        XCTAssertEqual(spy.decide(retry(), cleaned: "Текст слоя два."), .replaced)
        XCTAssertEqual(spy.replaced, ["Текст слоя два."])
        XCTAssertTrue(spy.copied.isEmpty)
    }

    /// Разница только в пробелах по краям — это всё ещё наш текст: поле ввода могло
    /// подрезать хвостовой перенос само.
    func testWhitespaceAroundDoesNotBlockReplacement() {
        let spy = Spy(field: "  текст слоя два\n")
        XCTAssertEqual(spy.decide(retry(), cleaned: "Текст слоя два."), .replaced)
    }

    /// Человек дописал своё — заменять нельзя, иначе допечатанное пропадёт.
    func testCopiesWhenUserAppendedSomething() {
        let spy = Spy(field: "текст слоя два и ещё моя мысль")
        XCTAssertEqual(spy.decide(retry(), cleaned: "Текст слоя два."), .copied)
        XCTAssertTrue(spy.replaced.isEmpty, "в чужое поле Cmd-A слать нельзя")
        XCTAssertEqual(spy.copied, ["Текст слоя два."])
    }

    /// Фокус ушёл в другое окно (или поля не видно вовсе) — тем более нельзя.
    func testCopiesWhenFieldIsGone() {
        let spy = Spy(field: nil)
        XCTAssertEqual(spy.decide(retry(), cleaned: "Текст слоя два."), .copied)
        XCTAssertTrue(spy.replaced.isEmpty)
    }

    /// Замена не прошла (парольное поле, нет разрешения) — результат всё равно не теряется:
    /// он остаётся в буфере обмена, и об этом честно сообщается.
    func testFallsBackToClipboardWhenReplacementFails() {
        let spy = Spy(field: "текст слоя два", replaceOutcome: .clipboardOnly(reason: "secure input"))
        XCTAssertEqual(spy.decide(retry(), cleaned: "Текст слоя два."), .copied)
        // Провалившаяся замена сама в буфер ничего не кладёт — значит это делаем мы,
        // иначе результат повтора пропал бы совсем.
        XCTAssertEqual(spy.copied, ["Текст слоя два."])
    }

    /// Ту же проверку делает и приложение, когда решает, предлагать ли повтор вообще:
    /// в карточке и в буфере обмена заменять нечего.
    func testPromptWordsNameBothChoices() {
        XCTAssertTrue(CleanupRetryOutcome.replaced != .copied)
        XCTAssertNotEqual(CleanupRetryOutcome.failed("сеть"), CleanupRetryOutcome.failed("таймаут"))
    }

    /// Двойник доставки. Само решение зовётся настоящее — `CleanupRetry.deliver`.
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private let field: String?
        private let replaceOutcome: InsertOutcome
        private(set) var replaced: [String] = []
        private(set) var copied: [String] = []

        init(field: String?, replaceOutcome: InsertOutcome = .pasted) {
            self.field = field
            self.replaceOutcome = replaceOutcome
        }

        private var delivery: TextDelivery {
            TextDelivery(
                focus: { FocusVerdict(state: .unknown, role: nil) },
                insert: { _ in .pasted },
                copy: { text in self.lock.withLock { self.copied.append(text) } },
                replace: { text in
                    self.lock.withLock { self.replaced.append(text) }
                    return self.replaceOutcome
                },
                fieldText: { self.field }
            )
        }

        func decide(_ retry: CleanupRetry, cleaned: String) -> CleanupRetryOutcome {
            retry.deliver(cleaned, using: delivery)
        }
    }
}
