import XCTest
@testable import Transcriber

/// Перевод карточки. Сеть тут не участвует: переводчик подставной, а проверяется то,
/// ради чего он и вынесен отдельным типом, — сколько раз его зовут и что видно на карточке.
@MainActor
final class CardTranslateTests: XCTestCase {

    /// Счётчик вызовов: «второй раз в сеть не ходим» — это утверждение о числе, а не о чувстве.
    private final class Counter: @unchecked Sendable {
        var calls = 0
    }

    private func makeCard(
        text: String = "привет из диктовки",
        available: Bool = true,
        counter: Counter = Counter(),
        answer: @escaping (String) async throws -> String = { "translation of \($0)" }
    ) -> CardPanel {
        CardPanel(
            text: text,
            translator: CardTranslator(
                isAvailable: { available },
                translate: { text in
                    counter.calls += 1
                    return try await answer(text)
                }
            )
        )
    }

    /// Перевод приезжает, показывается на карточке и уносится с ней: перетаскивание и
    /// копирование обязаны отдавать ТО, что сейчас видно.
    func testTranslationReplacesTheShownTextAndThePayload() async throws {
        let card = makeCard()
        card.translateForTesting()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(card.showsTranslationForTesting)
        XCTAssertEqual(card.displayedTextForTesting, "translation of привет из диктовки")
        XCTAssertEqual(card.dragTextForTesting, "translation of привет из диктовки")
    }

    /// Второе нажатие возвращает оригинал, третье — снова перевод, и всё это без единого
    /// нового запроса: перевод лежит в модели.
    func testToggleDoesNotRefetch() async throws {
        let counter = Counter()
        let card = makeCard(counter: counter)

        card.translateForTesting()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.calls, 1)
        XCTAssertTrue(card.showsTranslationForTesting)

        card.translateForTesting()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(card.showsTranslationForTesting, "вернулись к оригиналу")
        XCTAssertEqual(card.displayedTextForTesting, "привет из диктовки")

        card.translateForTesting()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(card.showsTranslationForTesting)
        XCTAssertEqual(counter.calls, 1, "перевод уже есть — в сеть больше не ходим")
    }

    /// Без GPT переводить нечем: кнопка приглушена и запроса не делает.
    func testUnavailableTranslatorNeverAsks() async throws {
        let counter = Counter()
        let card = makeCard(available: false, counter: counter)
        XCTAssertFalse(card.canTranslateForTesting)

        card.translateForTesting()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(counter.calls, 0)
        XCTAssertFalse(card.showsTranslationForTesting)
        XCTAssertEqual(card.displayedTextForTesting, "привет из диктовки")
    }

    /// Сбой перевода карточку не портит: остаётся оригинал плюс короткая жалоба.
    func testFailureKeepsTheOriginal() async throws {
        struct Boom: Error {}
        let card = makeCard(answer: { _ in throw Boom() })

        card.translateForTesting()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(card.showsTranslationForTesting)
        XCTAssertEqual(card.displayedTextForTesting, "привет из диктовки")
        XCTAssertNotNil(card.failureForTesting, "о неудаче карточка обязана сказать")
    }
}
