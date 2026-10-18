import XCTest
@testable import CribeCore

/// Три дефекта, найденные проверкой перед выпуском 0.5.0.
final class PrereleaseFixesTests: XCTestCase {

    // MARK: Оборванный поток

    /// Поток, закрытый без `response.completed`, — сбой, а не готовый ответ. Раньше
    /// обрывок уезжал в поле как вся чистка, без повтора и без плашки.
    func testStreamWithoutCompletionIsAnError() throws {
        var accumulator = SSEAccumulator()
        try accumulator.consume(#"data: {"type":"response.output_text.delta","delta":"половина"}"#)
        XCTAssertThrowsError(try accumulator.result()) { error in
            XCTAssertTrue(PostProcessor.isRetryable(error), "такой обрыв обязан повторяться: \(error)")
        }
    }

    func testCompletedStreamGivesItsText() throws {
        var accumulator = SSEAccumulator()
        try accumulator.consume(#"data: {"type":"response.output_text.delta","delta":"готово"}"#)
        try accumulator.consume(#"data: {"type":"response.completed"}"#)
        XCTAssertEqual(try accumulator.result(), "готово")
    }

    func testCompletedButEmptyIsEmpty() throws {
        var accumulator = SSEAccumulator()
        try accumulator.consume(#"data: {"type":"response.completed"}"#)
        XCTAssertThrowsError(try accumulator.result()) { error in
            guard case GPTClientError.empty = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Рассуждение на пути с API-ключом

    /// Модель по умолчанию обязана получать усилие на ОБОИХ путях. Проверка знала только
    /// `gpt-5`, и переход на `gpt-6-sol` молча выкинул усилие из запросов с API-ключом.
    func testDefaultModelGetsReasoningWithAPIKey() {
        XCTAssertTrue(GPTProtocol.supportsReasoning(model: GPTConfig.defaultModel, mode: .apiKey))
        let body = GPTProtocol.requestBody(
            model: GPTConfig.defaultModel, instructions: "i", input: "t", effort: "medium", mode: .apiKey
        )
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
    }

    /// Не-reasoning семейства по-прежнему без этих полей — публичный API отвечает на них 400.
    func testNonReasoningModelsStayWithout() {
        XCTAssertFalse(GPTProtocol.supportsReasoning(model: "gpt-4o", mode: .apiKey))
    }

    // MARK: Прогресс загрузки модели

    /// Присоединившийся к идущей загрузке сразу получает последнее состояние, а дальше —
    /// те же доли, что и начавший. Раньше он стоял на «0%» всю загрузку.
    func testLateJoinerCatchesUpAndFollows() {
        let fanout = ProgressFanout()
        let first = Box(), second = Box()

        XCTAssertNil(fanout.join { first.add($0) })
        fanout.send(.downloading(0.4))

        let catchUp = fanout.join { second.add($0) }
        guard case .downloading(let share)? = catchUp else { return XCTFail("догона нет") }
        XCTAssertEqual(share, 0.4, accuracy: 0.001)

        fanout.send(.loading)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.count, 1, "второй получил следующее состояние")
    }

    /// После загрузки — чистый лист: следующая не стартует с чужих долей.
    func testResetForgetsEverything() {
        let fanout = ProgressFanout()
        let box = Box()
        _ = fanout.join { box.add($0) }
        fanout.send(.downloading(0.9))
        fanout.reset()

        XCTAssertNil(fanout.join(nil))
        fanout.send(.loading)
        XCTAssertEqual(box.count, 1, "отписанный слушатель больше ничего не получает")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ASRModelState] = []
    func add(_ state: ASRModelState) { lock.lock(); states.append(state); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return states.count }
}
