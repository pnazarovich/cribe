import XCTest
@testable import Cribe
@testable import CribeCore

/// Чип очереди в пилюле. Пилюля показывает ОДНО дело, а с наложением их бывает два сразу,
/// поэтому чип обязан считать «сколько ещё помимо названного» — иначе одна и та же диктовка
/// будет посчитана дважды, и человек решит, что в работе больше, чем есть.
final class QueueBadgeTests: XCTestCase {

    /// На записи пилюля называет живую диктовку, а очередь — это всё, что записано до неё.
    func testRecordingCountsTheWholeQueue() {
        XCTAssertEqual(PanelPill.queueBadge(state: .recording(live: "", level: 0), pending: 0), 0)
        XCTAssertEqual(PanelPill.queueBadge(state: .recording(live: "", level: 0), pending: 1), 1)
        XCTAssertEqual(
            PanelPill.queueBadge(
                state: .recording(live: "", level: 0),
                pending: DictationController.maxPending
            ),
            DictationController.maxPending
        )
    }

    /// На обработке пилюля уже называет первую диктовку из очереди — в чип идут остальные.
    /// Одна-единственная диктовка чипа не получает вовсе: она и есть строка.
    func testProcessingExcludesTheDictationThePillNames() {
        XCTAssertEqual(PanelPill.queueBadge(state: .transcribing, pending: 1), 0)
        XCTAssertEqual(PanelPill.queueBadge(state: .transcribing, pending: 3), 2)
        XCTAssertEqual(PanelPill.queueBadge(state: .cleaning, pending: 2), 1)
    }

    /// Итоговые вспышки чипа не носят: до них очередь уже пуста, а вспышка «Вставлено»
    /// с числом рядом читалась бы как «вставлено две штуки».
    func testFlashesNeverShowTheBadge() {
        let flashes: [DictationState] = [
            .idle, .inserted, .carded, .cancelled, .degraded("без AI-чистки"), .error("сбой"),
            .preparingModel(.warming(since: Date())),
        ]
        for state in flashes {
            XCTAssertEqual(PanelPill.queueBadge(state: state, pending: 2), 0, "\(state)")
        }
    }
}
