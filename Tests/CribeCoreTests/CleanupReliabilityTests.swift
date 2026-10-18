import XCTest
@testable import CribeCore

/// Надёжность GPT-слоя: что повторять, сколько ждать и что считать сбоем.
///
/// Владелец жаловался, что примерно каждая пятая чистка через Codex не проходит и её
/// приходится повторять руками. Замер 2026-10-18 (55 живых вызовов) сбоя не поймал,
/// а исследование нашло причину в другом месте: с 9 октября у Codex идут ошибки
/// «модель перегружена», и официальный клиент прячет их за тихими повторами. У Cribe
/// повторов не было вовсе — каждая такая ошибка сразу становилась плашкой.
final class CleanupReliabilityTests: XCTestCase {

    private struct Flaky: Error {}

    /// Проходящие сбои повторяются, пределы — нет.
    func testWhatIsWorthRetrying() {
        let retry: [Error] = [
            PostProcessorError.timedOut,
            URLError(.networkConnectionLost),
            URLError(.timedOut),
            GPTClientError.empty,
            GPTClientError.http(503, "Selected model is at capacity"),
            GPTClientError.http(500, ""),
            GPTClientError.http(429, "Too many requests, slow down"),
            GPTClientError.stream("An error occurred while processing your request", code: "server_error"),
            GPTClientError.stream("stream closed before response.completed"),
        ]
        for error in retry {
            XCTAssertTrue(PostProcessor.isRetryable(error), "повторять: \(error)")
        }

        let stop: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            GPTClientError.missingAPIKey,
            GPTClientError.http(401, "Unauthorized"),
            GPTClientError.http(400, "Bad request"),
            // Лимит аккаунта: повтор его не снимет, а потратит остаток.
            GPTClientError.http(429, "{\"error\":{\"type\":\"usage_limit_reached\"}}"),
            GPTClientError.stream("You've hit your usage limit", code: "usage_limit_reached"),
            GPTClientError.stream("You exceeded your current quota", code: "insufficient_quota"),
            GPTClientError.stream("bad prompt", code: "invalid_prompt"),
            // Ответ оборвала сама модель: повтор вернёт тот же обрывок.
            GPTClientError.stream("ответ оборван", code: "incomplete"),
            CodexAuthError.notAuthorized,
        ]
        for error in stop {
            XCTAssertFalse(PostProcessor.isRetryable(error), "не повторять: \(error)")
        }
    }

    /// Две осечки подряд — и третья попытка отдаёт текст. Человеку ничего не надо жать.
    func testTransientFailuresAreRetriedSilently() async throws {
        let calls = Counter()
        let answer = try await PostProcessor.withRetries(deadline: 10, pause: { _ in }) { _ in
            if await calls.next() < 3 { throw GPTClientError.http(503, "at capacity") }
            return "готово"
        }
        XCTAssertEqual(answer, "готово")
        let count = await calls.value
        XCTAssertEqual(count, 3)
    }

    /// Предел аккаунта не повторяется вовсе: одна попытка, и сразу честная причина.
    func testAllowanceIsNotRetried() async {
        let calls = Counter()
        do {
            _ = try await PostProcessor.withRetries(deadline: 10, pause: { _ in }) { _ -> String in
                _ = await calls.next()
                throw GPTClientError.stream("usage limit", code: "usage_limit_reached")
            }
            XCTFail("должно было упасть")
        } catch {
            let count = await calls.value
            XCTAssertEqual(count, 1)
        }
    }

    /// Больше трёх попыток не бывает, даже если сервер отказывает мгновенно.
    func testAttemptsAreBounded() async {
        let calls = Counter()
        do {
            _ = try await PostProcessor.withRetries(deadline: 10, pause: { _ in }) { _ -> String in
                _ = await calls.next()
                throw GPTClientError.http(503, "at capacity")
            }
            XCTFail("должно было упасть")
        } catch {
            let count = await calls.value
            XCTAssertEqual(count, 3)
        }
    }

    /// Бюджет — два срока попытки. Попытка, упёршаяся в срок, оставляет место ровно
    /// для одной полноценной второй, а третьей уже не начинается: диктовка не ждёт
    /// минутами, как официальный клиент.
    func testBudgetStopsSlowRetries() async {
        let calls = Counter()
        do {
            // Срок в секунду, а не в доли: пауза между попытками (200 мс) не масштабируется,
            // и при сроке, соизмеримом с ней, вторая попытка законно не влезала бы в бюджет.
            _ = try await PostProcessor.withRetries(deadline: 1, pause: { _ in }) { _ -> String in
                _ = await calls.next()
                try await Task.sleep(for: .milliseconds(1_050))
                throw PostProcessorError.timedOut
            }
            XCTFail("должно было упасть")
        } catch {
            let count = await calls.value
            XCTAssertEqual(count, 2)
        }
    }

    /// Паузы между попытками — 200 мс с удвоением, как у официального клиента.
    func testBackoffDoubles() async throws {
        let pauses = Recorder()
        let calls = Counter()
        _ = try await PostProcessor.withRetries(deadline: 10, pause: { await pauses.add($0) }) { _ in
            if await calls.next() < 3 { throw URLError(.networkConnectionLost) }
            return "ok"
        }
        let recorded = await pauses.items
        XCTAssertEqual(recorded, [.milliseconds(200), .milliseconds(400)])
    }

    /// Перевод получает свой срок: длинный перевод с усилием `high` сам по себе подходил
    /// к прежним 10 секундам (замер: 5,2–9,0 с).
    func testTranslationHasItsOwnDeadline() {
        XCTAssertEqual(PostProcessor.attemptDeadline(translating: false), 10)
        XCTAssertGreaterThan(PostProcessor.attemptDeadline(translating: true), 20)
    }

    /// Ключ кэша устойчив для одинаковой подсказки и меняется вместе с ней, с моделью
    /// и с усилием. И выглядит как UUID — тем же значением уходит `session-id`.
    func testCacheKey() {
        let a = PostProcessor.cacheKey(instructions: "промпт", model: "gpt-5.6-terra", effort: "low")
        XCTAssertEqual(a, PostProcessor.cacheKey(instructions: "промпт", model: "gpt-5.6-terra", effort: "low"))
        XCTAssertNotEqual(a, PostProcessor.cacheKey(instructions: "другой", model: "gpt-5.6-terra", effort: "low"))
        XCTAssertNotEqual(a, PostProcessor.cacheKey(instructions: "промпт", model: "gpt-5.6-terra", effort: "high"))
        XCTAssertNotEqual(a, PostProcessor.cacheKey(instructions: "промпт", model: "gpt-6-luna", effort: "low"))
        XCTAssertNotNil(UUID(uuidString: a), a)
    }

    /// Ключ уходит в тело запроса — так делает официальный клиент.
    func testCacheKeyGoesIntoTheRequest() {
        let body = GPTProtocol.requestBody(
            model: "gpt-5.6-terra", instructions: "i", input: "t", effort: "low", mode: .codex,
            promptCacheKey: "k"
        )
        XCTAssertEqual(body["prompt_cache_key"] as? String, "k")
        let without = GPTProtocol.requestBody(model: "gpt-5.6-terra", instructions: "i", input: "t", effort: "low", mode: .codex)
        XCTAssertNil(without["prompt_cache_key"])
    }

    /// Оборванный моделью ответ — ошибка, а не готовая чистка. Раньше кадр
    /// `response.incomplete` проходил мимо, и обрывок уезжал в поле как весь текст.
    func testIncompleteResponseIsAnError() {
        var accumulator = SSEAccumulator()
        XCTAssertNoThrow(try accumulator.consume(#"data: {"type":"response.output_text.delta","delta":"половина"}"#))
        XCTAssertThrowsError(try accumulator.consume(
            #"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
        )) { error in
            guard case GPTClientError.stream(let message, let code) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(code, "incomplete")
            XCTAssertTrue(message.contains("max_output_tokens"), message)
        }
    }

    /// Код ошибки достаётся из кадра — по нему и решается, повторять ли.
    func testErrorCodeIsCarried() {
        var accumulator = SSEAccumulator()
        XCTAssertThrowsError(try accumulator.consume(
            #"data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"boom"}}}"#
        )) { error in
            guard case GPTClientError.stream(let message, let code) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(code, "server_error")
            XCTAssertEqual(message, "boom")
        }
    }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

private actor Recorder {
    private(set) var items: [Duration] = []
    func add(_ item: Duration) { items.append(item) }
}
