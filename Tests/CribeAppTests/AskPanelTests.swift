import AppKit
import XCTest
@testable import Cribe
@testable import CribeCore

/// Очередь вопросов о словаре. Плашка держит настоящее окно, поэтому проверяется то, что
/// от окна не зависит: кого спрашивают, в каком порядке и кто получает ответ.
@MainActor
final class AskPanelTests: XCTestCase {

    private let first = LearnRequest(correction: Correction(heard: "клайв", meant: "Cribe"))
    private let second = LearnRequest(correction: Correction(heard: "впс", meant: "VPS"))

    /// Вопросы идут по одному: на экране один, остальные ждут.
    func testQuestionsWaitTheirTurn() {
        let panel = AskPanel()
        panel.ask(first) { _ in }
        panel.ask(second) { _ in }
        XCTAssertEqual(panel.waiting, 2)
    }

    /// Ответ достаётся тому вопросу, который на экране, — и только ему.
    func testAnswerReachesOnlyTheQuestionOnScreen() {
        let panel = AskPanel()
        var answered: [String] = []
        panel.ask(first) { answered.append("клайв:\($0)") }
        panel.ask(second) { answered.append("впс:\($0)") }

        panel.answer(true)

        XCTAssertEqual(answered, ["клайв:true"])
        XCTAssertEqual(panel.waiting, 1, "второй остаётся ждать своей очереди")
    }

    /// Главное правило очереди. Молчание значит, что человек на экран не смотрит, — и
    /// показывать ему следом ещё четыре плашки бессмысленно. Ничего при этом не теряется:
    /// пары не отвергнуты, а ошибка, которая их породила, повторится и спросит снова.
    func testUnansweredQuestionTakesTheQueueWithIt() {
        let panel = AskPanel()
        var answered: [Bool] = []
        panel.ask(first) { answered.append($0) }
        panel.ask(second) { answered.append($0) }

        panel.answer(nil)

        XCTAssertEqual(panel.waiting, 0, "очередь снята целиком")
        XCTAssertEqual(answered, [], "молчание — не ответ, и обработчик не зовётся")
    }

    /// Та же пара, пока прошлый вопрос ещё висит: диктовка могла повториться, а спрашивать
    /// дважды об одном и том же незачем.
    func testSameCorrectionIsNotAskedTwice() {
        let panel = AskPanel()
        panel.ask(first) { _ in }
        panel.ask(first) { _ in }
        panel.ask(second) { _ in }
        XCTAssertEqual(panel.waiting, 2)
    }

    /// Обычный случай: причёсывание слова не трогало — говорить не о чем.
    func testQuestionNamesOnePairWhenNothingWasTidied() {
        XCTAssertEqual(
            AskLayout.question(first),
            "Услышал «клайв», вы исправили на «Cribe». В словарь?"
        )
    }

    /// Случай, ради которого вопрос вообще знает два слова. Человек правил «scribe» —
    /// он его видел на экране; запомнится «клайв» — его услышало распознавание. Спросить
    /// только про «клайв» значило бы спросить про слово, которого человек не видел.
    func testQuestionNamesBothWordsWhenTidyingSwappedThem() {
        let request = LearnRequest(
            correction: Correction(heard: "клайв", meant: "Cribe"),
            edited: "scribe"
        )
        XCTAssertEqual(
            AskLayout.question(request),
            "Услышал «клайв» (в тексте — «scribe»), вы исправили на «Cribe». В словарь?"
        )
    }

    /// Плашка кроится по длине пары: длинный термин обязан делать её шире.
    func testCapsuleGrowsWithTheWords() {
        let short = AskPanel.capsuleWidth(for: LearnRequest(correction: Correction(heard: "впс", meant: "VPS")))
        let long = AskPanel.capsuleWidth(
            for: LearnRequest(correction: Correction(heard: "гиперконвергентный", meant: "hyperconverged"))
        )
        XCTAssertGreaterThan(long, short)
        XCTAssertLessThanOrEqual(long, AskLayout.maximumWidth, "но не сверх потолка")
    }
}
