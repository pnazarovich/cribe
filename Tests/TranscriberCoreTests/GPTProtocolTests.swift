import XCTest
@testable import TranscriberCore

/// Тесты чистых частей GPT-слоя: разбор JWT, разбор `interval`, сборка тела запроса, SSE-парсер.
/// Сеть не используется, Keychain не трогаем.
final class GPTProtocolTests: XCTestCase {

    // MARK: - Синтетический JWT

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeToken(accountId: String?, exp: TimeInterval?) -> String {
        var payload: [String: Any] = [:]
        if let accountId {
            payload["https://api.openai.com/auth"] = ["chatgpt_account_id": accountId]
        }
        if let exp {
            payload["exp"] = exp
        }
        let header = base64url(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
        let body = base64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).signature"
    }

    func testAccountIdParsedFromAccessToken() {
        let token = makeToken(accountId: "acc_12345", exp: nil)
        XCTAssertEqual(CodexProtocol.accountId(fromAccessToken: token), "acc_12345")
    }

    func testAccountIdMissingClaimReturnsNil() {
        let token = makeToken(accountId: nil, exp: 1_000)
        XCTAssertNil(CodexProtocol.accountId(fromAccessToken: token))
    }

    func testMalformedTokenReturnsNil() {
        XCTAssertNil(CodexProtocol.accountId(fromAccessToken: "not-a-jwt"))
        XCTAssertNil(CodexProtocol.expiry(fromAccessToken: "a.b"))
    }

    func testExpiryParsedFromAccessToken() {
        let exp: TimeInterval = 1_800_000_000
        let token = makeToken(accountId: "acc_1", exp: exp)
        XCTAssertEqual(CodexProtocol.expiry(fromAccessToken: token)?.timeIntervalSince1970, exp)
    }

    func testNeedsRefreshWhenExpiryWithinFiveMinutes() {
        let soon = makeToken(accountId: "acc_1", exp: Date().addingTimeInterval(60).timeIntervalSince1970)
        let later = makeToken(accountId: "acc_1", exp: Date().addingTimeInterval(3600).timeIntervalSince1970)
        XCTAssertTrue(CodexProtocol.needsRefresh(accessToken: soon))
        XCTAssertFalse(CodexProtocol.needsRefresh(accessToken: later))
        // Без разбираемого exp считаем, что обновление нужно.
        XCTAssertTrue(CodexProtocol.needsRefresh(accessToken: "garbage"))
    }

    // MARK: - interval приходит строкой или числом

    func testIntervalParsesString() {
        XCTAssertEqual(CodexProtocol.interval(from: "7"), 7)
    }

    func testIntervalParsesNumber() {
        XCTAssertEqual(CodexProtocol.interval(from: 3), 3)
        XCTAssertEqual(CodexProtocol.interval(from: 2.5), 2.5)
    }

    func testIntervalFallsBackToDefault() {
        XCTAssertEqual(CodexProtocol.interval(from: nil), CodexProtocol.defaultPollInterval)
        XCTAssertEqual(CodexProtocol.interval(from: "abc"), CodexProtocol.defaultPollInterval)
        XCTAssertEqual(CodexProtocol.interval(from: "0"), CodexProtocol.defaultPollInterval)
    }

    // MARK: - Поллинг: 403/404 = «ещё ждём»

    func testPendingStatusCodes() {
        XCTAssertTrue(CodexProtocol.isPending(status: 403))
        XCTAssertTrue(CodexProtocol.isPending(status: 404))
        XCTAssertFalse(CodexProtocol.isPending(status: 200))
        XCTAssertFalse(CodexProtocol.isPending(status: 500))
    }

    func testTerminalRefreshErrors() {
        XCTAssertTrue(CodexProtocol.isTerminalRefreshError(status: 400, body: #"{"error":"refresh_token_expired"}"#))
        XCTAssertTrue(CodexProtocol.isTerminalRefreshError(status: 400, body: #"{"error":"refresh_token_reused"}"#))
        XCTAssertTrue(CodexProtocol.isTerminalRefreshError(status: 200, body: "token invalidated"))
        XCTAssertFalse(CodexProtocol.isTerminalRefreshError(status: 500, body: "gateway timeout"))
    }

    // MARK: - Тело запроса

    func testRequestBodyShape() throws {
        let body = GPTProtocol.requestBody(
            model: "gpt-5.2",
            instructions: "инструкции",
            input: "текст",
            effort: "medium",
            mode: .codex
        )

        XCTAssertEqual(body["model"] as? String, "gpt-5.2")
        XCTAssertEqual(body["instructions"] as? String, "инструкции")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[0]["text"] as? String, "текст")

        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testCodexNormalizesMinimalAndNoneToLow() {
        XCTAssertEqual(GPTProtocol.normalizedEffort("minimal", mode: .codex), "low")
        XCTAssertEqual(GPTProtocol.normalizedEffort("none", mode: .codex), "low")
        XCTAssertEqual(GPTProtocol.normalizedEffort("high", mode: .codex), "high")

        let body = GPTProtocol.requestBody(
            model: "gpt-5.2", instructions: "i", input: "t", effort: "minimal", mode: .codex
        )
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testAPIKeyModeKeepsMinimalEffort() {
        XCTAssertEqual(GPTProtocol.normalizedEffort("minimal", mode: .apiKey), "minimal")
        XCTAssertEqual(GPTProtocol.normalizedEffort("none", mode: .apiKey), "none")
    }

    // MARK: - Reasoning-поля только там, где их понимают

    /// codex + none: нормализация в `low` идёт первой, поэтому поля остаются на месте.
    func testCodexNoneEffortStillSendsReasoning() {
        let body = GPTProtocol.requestBody(
            model: "gpt-5.2", instructions: "i", input: "t", effort: "none", mode: .codex
        )
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
    }

    /// Публичный API отвечает 400 на reasoning-поля для не-reasoning моделей.
    func testAPIKeyNonReasoningModelOmitsReasoningAndInclude() {
        let body = GPTProtocol.requestBody(
            model: "gpt-4o", instructions: "i", input: "t", effort: "medium", mode: .apiKey
        )
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["include"])
        // Остальное тело не пострадало.
        XCTAssertEqual(body["model"] as? String, "gpt-4o")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testAPIKeyNoneEffortOmitsReasoningAndInclude() {
        let body = GPTProtocol.requestBody(
            model: "gpt-5.2", instructions: "i", input: "t", effort: "none", mode: .apiKey
        )
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["include"])
    }

    func testAPIKeyReasoningModelKeepsReasoningAndInclude() {
        let body = GPTProtocol.requestBody(
            model: "gpt-5.6-luna", instructions: "i", input: "t", effort: "minimal", mode: .apiKey
        )
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "minimal")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
    }

    func testSupportsReasoningByModelFamily() {
        XCTAssertTrue(GPTProtocol.supportsReasoning(model: "gpt-5.2", mode: .apiKey))
        XCTAssertTrue(GPTProtocol.supportsReasoning(model: "gpt-5.6-luna", mode: .apiKey))
        XCTAssertFalse(GPTProtocol.supportsReasoning(model: "gpt-4o", mode: .apiKey))
        XCTAssertFalse(GPTProtocol.supportsReasoning(model: "gpt-4.1-mini", mode: .apiKey))
        // Codex-бэкенд отдаёт только reasoning-модели — слаг не проверяем.
        XCTAssertTrue(GPTProtocol.supportsReasoning(model: "codex-mini", mode: .codex))
    }

    // MARK: - SSE

    private let deltaFixture = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Привет"}

    data: {"type":"response.output_text.delta","delta":", мир"}

    data: {"type":"response.reasoning_summary_text.delta","delta":"игнор"}

    data: {"type":"response.completed","response":{"id":"resp_1"}}

    data: [DONE]
    """

    func testSSEConcatenatesDeltasUntilCompleted() throws {
        var accumulator = SSEAccumulator()
        for line in deltaFixture.components(separatedBy: "\n") {
            try accumulator.consume(line)
        }
        XCTAssertEqual(accumulator.text, "Привет, мир")
        XCTAssertTrue(accumulator.isCompleted)
    }

    func testSSEFailedThrows() {
        var accumulator = SSEAccumulator()
        let fixture = """
        data: {"type":"response.output_text.delta","delta":"частично"}
        data: {"type":"response.failed","response":{"error":{"message":"rate limit exceeded"}}}
        """
        XCTAssertThrowsError(
            try fixture.components(separatedBy: "\n").forEach { try accumulator.consume($0) }
        ) { error in
            XCTAssertTrue("\(error)".contains("rate limit exceeded"), "ожидали текст ошибки, получили \(error)")
        }
    }

    func testSSETopLevelErrorFrameThrows() {
        var accumulator = SSEAccumulator()
        let line = #"data: {"type":"error","message":"You've hit your usage limit"}"#
        XCTAssertThrowsError(try accumulator.consume(line)) { error in
            XCTAssertTrue("\(error)".contains("usage limit"), "ожидали причину лимита, получили \(error)")
        }
    }

    func testSSEUnknownErrorLikeFrameThrowsWithTypeAndMessage() {
        var accumulator = SSEAccumulator()
        let line = #"data: {"type":"response.output_item.error","error":{"message":"tool crashed"}}"#
        XCTAssertThrowsError(try accumulator.consume(line)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("response.output_item.error"), text)
            XCTAssertTrue(text.contains("tool crashed"), text)
        }
    }

    func testSSEUnknownErrorLikeFrameWithoutMessageThrowsWithType() {
        var accumulator = SSEAccumulator()
        XCTAssertThrowsError(try accumulator.consume(#"data: {"type":"stream.error"}"#)) { error in
            XCTAssertTrue("\(error)".contains("stream.error"), "\(error)")
        }
    }

    func testSSEUnknownNonErrorFramesStillIgnored() throws {
        var accumulator = SSEAccumulator()
        try accumulator.consume(#"data: {"type":"response.in_progress"}"#)
        try accumulator.consume(#"data: {"type":"response.output_item.added","item":{"id":"1"}}"#)
        XCTAssertEqual(accumulator.text, "")
        XCTAssertFalse(accumulator.isCompleted)
    }

    // MARK: - Разбор списка моделей

    func testCodexModelsFilteredByVisibility() throws {
        let json = """
        {"models":[{"slug":"gpt-5.2","visibility":"list"},
                   {"slug":"gpt-internal","visibility":"hidden"},
                   {"slug":"gpt-5.6-luna","visibility":"list"}]}
        """
        XCTAssertEqual(try GPTProtocol.codexModels(from: Data(json.utf8)), ["gpt-5.2", "gpt-5.6-luna"])
    }

    func testAPIModelsFilteredAndSortedByCreatedDesc() throws {
        let json = """
        {"data":[{"id":"gpt-5.2","created":100},
                 {"id":"whisper-1","created":300},
                 {"id":"gpt-5.6-luna","created":200}]}
        """
        XCTAssertEqual(try GPTProtocol.apiModels(from: Data(json.utf8)), ["gpt-5.6-luna", "gpt-5.2"])
    }

    // MARK: - Дефолты и промпт

    func testDefaultModelsPerMode() {
        XCTAssertEqual(GPTConfig.defaultModel(for: .codex), "gpt-5.2")
        XCTAssertEqual(GPTConfig.defaultModel(for: .apiKey), "gpt-5.6-luna")
        XCTAssertEqual(GPTConfig.defaultEffort, "low")
    }

    func testSystemPromptContainsDictionaryPairsAndGuards() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        let prompt = PostProcessor.systemPrompt(entries: entries, language: .ru)
        XCTAssertTrue(prompt.contains("гитхаб"))
        XCTAssertTrue(prompt.contains("GitHub"))
        XCTAssertTrue(prompt.lowercased().contains("никогда"))

        let uk = PostProcessor.systemPrompt(entries: entries, language: .uk)
        XCTAssertTrue(uk.contains("GitHub"))
        XCTAssertNotEqual(uk, prompt)
    }

    func testTranslatePromptAsksForEnglishAndKeepsCleanupRules() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        let plain = PostProcessor.systemPrompt(entries: entries, language: .ru)
        let translating = PostProcessor.systemPrompt(entries: entries, language: .ru, translateToEnglish: true)

        XCTAssertFalse(plain.lowercased().contains("англи"), "обычный промпт не должен просить перевод")
        XCTAssertTrue(translating.lowercased().contains("англи"))
        XCTAssertTrue(translating.lowercased().contains("только"), "перевод возвращается без оригинала")
        // Правила чистки и словарь никуда не делись.
        XCTAssertTrue(translating.contains("гитхаб"))
        XCTAssertTrue(translating.contains("GitHub"))
        XCTAssertTrue(translating.lowercased().contains("никогда"))
        XCTAssertTrue(translating.contains("филлер"))
    }

    func testTranslatePromptUkrainian() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гітхаб"])]
        let plain = PostProcessor.systemPrompt(entries: entries, language: .uk)
        let translating = PostProcessor.systemPrompt(entries: entries, language: .uk, translateToEnglish: true)

        XCTAssertFalse(plain.lowercased().contains("англі"))
        XCTAssertTrue(translating.lowercased().contains("англі"))
        XCTAssertTrue(translating.contains("GitHub"))
        XCTAssertNotEqual(translating, plain)
    }
}
