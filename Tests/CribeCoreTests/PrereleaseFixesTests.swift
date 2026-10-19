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

/// Режим Fast для чистки через вход ChatGPT.
final class FastCleanupTests: XCTestCase {

    /// Через вход ChatGPT чистка и перевод идут в режиме Fast: при той же модели ожидание
    /// первого слова падает с ~5 с до ~1,2 с.
    func testCodexPathUsesFastTier() {
        let defaults = UserDefaults(suiteName: "FastCleanupTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.gptMode = .codex
        XCTAssertEqual(settings.gptConfig.serviceTier, "priority")
        XCTAssertEqual(settings.translateGPTConfig.serviceTier, "priority")
    }

    /// С API-ключом — нет: там Fast вдвое дороже деньгами, а платить чужим ключом без спроса
    /// незачем.
    func testAPIKeyPathStaysStandard() {
        let defaults = UserDefaults(suiteName: "FastCleanupTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.gptMode = .apiKey
        XCTAssertNil(settings.gptConfig.serviceTier)
        XCTAssertNil(settings.translateGPTConfig.serviceTier)
    }

    /// Отказ, после которого стоит попробовать без Fast. Приложение стоит не только у
    /// владельца, а доступен ли Fast на любом тарифе ChatGPT — нигде не сказано.
    func testWhatLooksLikeRefusingFast() {
        XCTAssertTrue(PostProcessor.refusesFast(GPTClientError.http(400, "Unsupported service_tier: priority")))
        XCTAssertTrue(PostProcessor.refusesFast(GPTClientError.stream("Fast mode is not available on your plan", code: "invalid_request_error")))

        // Проходящие сбои лечатся обычным повтором, а не отказом от Fast.
        XCTAssertFalse(PostProcessor.refusesFast(GPTClientError.http(503, "at capacity")))
        XCTAssertFalse(PostProcessor.refusesFast(PostProcessorError.timedOut))
        // Лимит и авторизация без Fast лучше не станут.
        XCTAssertFalse(PostProcessor.refusesFast(GPTClientError.http(429, "usage_limit_reached")))
        XCTAssertFalse(PostProcessor.refusesFast(GPTClientError.stream("usage limit", code: "usage_limit_reached")))
        XCTAssertFalse(PostProcessor.refusesFast(GPTClientError.http(401, "Unauthorized")))
        // Оборванный моделью ответ — не про уровень обслуживания.
        XCTAssertFalse(PostProcessor.refusesFast(GPTClientError.stream("ответ оборван", code: "incomplete")))
    }

    /// Уровень уходит в тело запроса, а без него поля нет вовсе.
    func testServiceTierGoesIntoTheRequest() {
        let fast = GPTProtocol.requestBody(
            model: "gpt-6-sol", instructions: "i", input: "t", effort: "low", mode: .codex, serviceTier: "priority"
        )
        XCTAssertEqual(fast["service_tier"] as? String, "priority")
        let standard = GPTProtocol.requestBody(model: "gpt-6-sol", instructions: "i", input: "t", effort: "low", mode: .codex)
        XCTAssertNil(standard["service_tier"])
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ASRModelState] = []
    func add(_ state: ASRModelState) { lock.lock(); states.append(state); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return states.count }
}
