import XCTest
@testable import CribeCore

/// Тесты чистых частей GPT-слоя: разбор JWT, разбор `interval`, сборка тела запроса, SSE-парсер.
/// Сеть не используется, хранилище секретов не трогаем.
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
        XCTAssertEqual(GPTConfig.defaultModel(for: .codex), "gpt-5.6-terra")
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

        // Ищем саму просьбу перевести, а не слово «английский»: про английское написание
        // терминов говорит и обычная чистка — она возвращает латиницу названиям, которые
        // распознавание записало на слух.
        XCTAssertFalse(plain.contains("переведи результат"), "обычный промпт не должен просить перевод")
        XCTAssertTrue(translating.contains("переведи результат"))
        XCTAssertTrue(translating.lowercased().contains("только"), "перевод возвращается без оригинала")
        // Правила чистки и словарь никуда не делись.
        XCTAssertTrue(translating.contains("гитхаб"))
        XCTAssertTrue(translating.contains("GitHub"))
        XCTAssertTrue(translating.lowercased().contains("никогда"))
        XCTAssertTrue(translating.contains("филлер"))
    }

    /// Диктовка смешанная: русская речь с украинскими словами и латиницей — норма.
    /// Прежнее «Сохраняй язык» (в единственном числе) толкало модель нормализовать
    /// украинские вкрапления в русские, и правило обязано стоять во всех четырёх вариантах
    /// промпта — иначе на переводе или на украинской сессии дыра остаётся.
    func testMixedLanguageRuleInEveryPromptVariant() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        for translating in [false, true] {
            let ru = PostProcessor.systemPrompt(entries: entries, language: .ru, translateToEnglish: translating)
            XCTAssertTrue(ru.contains("Речь смешанная"), ru)
            XCTAssertTrue(ru.contains("НИКОГДА не переводи между русским и украинским"), ru)
            XCTAssertFalse(ru.contains("Сохраняй язык,"), "правило в единственном числе должно уйти")

            let uk = PostProcessor.systemPrompt(entries: entries, language: .uk, translateToEnglish: translating)
            XCTAssertTrue(uk.contains("Мовлення змішане"), uk)
            XCTAssertTrue(uk.contains("НІКОЛИ не перекладай між російською та українською"), uk)
            XCTAssertFalse(uk.contains("Зберігай мову,"), "правило в единственном числе должно уйти")
        }
    }

    /// Вкрапления не имеют права утащить за собой весь текст. Слой 1 на смешанной речи
    /// украинизирует и русскую основу, и правило про доминирующий язык — то единственное,
    /// что может вернуть её на место: язык сессии здесь известен точно.
    func testDominantLanguageRuleInEveryPromptVariant() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        for translating in [false, true] {
            let ru = PostProcessor.systemPrompt(entries: entries, language: .ru, translateToEnglish: translating)
            XCTAssertTrue(ru.contains("Язык этой диктовки — русский"), ru)
            XCTAssertTrue(ru.contains("не переписывай"), ru)
            // И одновременно — запрет русифицировать настоящие украинские слова.
            XCTAssertTrue(ru.contains("оставь украинскими"), ru)

            let uk = PostProcessor.systemPrompt(entries: entries, language: .uk, translateToEnglish: translating)
            XCTAssertTrue(uk.contains("Мова цього диктування — українська"), uk)
            XCTAssertTrue(uk.contains("не переписуй"), uk)
            XCTAssertTrue(uk.contains("залиши російськими"), uk)
        }
    }

    /// Запрет менять язык не имеет права спорить с переводом: на переводящем вызове он
    /// действует только на чистке, а сам перевод остаётся отдельным шагом.
    func testDominantLanguageRuleDoesNotFightTranslation() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        let ru = PostProcessor.systemPrompt(entries: entries, language: .ru, translateToEnglish: true)
        XCTAssertTrue(ru.contains("на чистке целиком на другой язык его не переписывай"), ru)
        XCTAssertTrue(ru.contains("на английский текст уедет отдельным шагом ниже"), ru)
        XCTAssertFalse(ru.contains("целиком на другой язык текст не переписывай"), ru)

        let uk = PostProcessor.systemPrompt(entries: entries, language: .uk, translateToEnglish: true)
        XCTAssertTrue(uk.contains("на чистці цілком іншою мовою його не переписуй"), uk)
        XCTAssertTrue(uk.contains("англійською текст поїде окремим кроком нижче"), uk)
    }

    /// Правило обратного чтения. Замерено на трёх диктовках про один проект: чистка сделала
    /// из «джиклан» то «G-Clan», то «GCLID» — второе не описка, а ДРУГОЙ существующий термин
    /// Google Ads вместо имени клиента. Такую подмену не видно глазом, поэтому в промпте нужен
    /// проверяемый критерий, а не просьба быть аккуратнее.
    func testReadBackRuleGuardsAgainstSubstitutedTerms() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        for engine in RecognitionEngine.allCases {
            let ru = PostProcessor.systemPrompt(entries: entries, language: .ru, engine: engine)
            XCTAssertTrue(ru.contains("читаться обратно в услышанное"), ru)
            XCTAssertTrue(ru.contains("GCLID"), ru)
            // И обратная сторона: осторожность не должна превращаться в отказ латинизировать
            // то, что подходит по звучанию, — на этом терялось «Fable».
            XCTAssertTrue(ru.contains("не повод осторожничать"), ru)
            XCTAssertTrue(ru.contains("Fable"), ru)
            XCTAssertTrue(ru.contains("ОДИНАКОВО"), ru)
        }
    }

    /// Верность речи и омофоны. Оба правила — из замера: чистка переставляла слова, меняла
    /// наклонение («поставь» → «поставили»), срезала начало фразы и выбирала «компании»
    /// там, где та же диктовка дальше говорила «рекламные кампании».
    func testFaithfulnessAndHomophoneRules() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        for translating in [false, true] {
            let ru = PostProcessor.systemPrompt(
                entries: entries, language: .ru, translateToEnglish: translating
            )
            XCTAssertTrue(ru.contains("не превращай в «поставили»"), ru)
            XCTAssertTrue(ru.contains("Не срезай начало фразы"), ru)
            XCTAssertTrue(ru.contains("«рекламные кампании» (не «компании»)"), ru)
            // Русские аббревиатуры латинице не отдаём: «СТО» уезжало в «CTO».
            XCTAssertTrue(ru.contains("станция техобслуживания, а не CTO"), ru)
        }
    }

    /// Про Parakeet чистка обязана знать: латиницы у него на выходе не бывает вовсе, а значит
    /// словарные варианты — фонетические образцы, а не строки. Ровно на этом «прокид»
    /// становится Parakeet, чего прежний промпт не делал никогда.
    func testParakeetPromptExplainsTransliteration() {
        let entries = [DictionaryEntry(canonical: "Parakeet", variants: ["parakit"])]
        let parakeet = PostProcessor.systemPrompt(entries: entries, language: .ru, engine: .parakeet)
        XCTAssertTrue(parakeet.contains("Латиницей оно не пишет ВООБЩЕ"), parakeet)
        XCTAssertTrue(parakeet.contains("сопоставляй по звучанию"), parakeet)

        // Whisper латиницу выводит сама — ей этот абзац только мешал бы.
        for engine in [RecognitionEngine.fast, .precise] {
            let whisper = PostProcessor.systemPrompt(entries: entries, language: .ru, engine: engine)
            XCTAssertFalse(whisper.contains("Латиницей оно не пишет ВООБЩЕ"), whisper)
        }

        // Украинская и английская ветки про движок не знают вовсе — их правила свои.
        for language in [Language.uk, .en] {
            let other = PostProcessor.systemPrompt(entries: entries, language: language, engine: .parakeet)
            XCTAssertFalse(other.contains("Латиницей оно не пишет ВООБЩЕ"), other)
        }
    }

    /// Каноническая форма бывает кириллической («ТЗ», «аппрувить»), а запрет переводить
    /// словарные термины исключений не знал — и английский перевод выходил с кириллицей
    /// внутри: «We need to approve the ТЗ». Воспроизводилось 3 раза из 3 на живой записи.
    func testTranslationTranslatesCyrillicCanonicalForms() {
        let entries = [
            DictionaryEntry(canonical: "ТЗ", variants: ["тэ зэ"]),
            DictionaryEntry(canonical: "pull request", variants: ["пул реквест"]),
        ]
        for language in [Language.ru, .uk] {
            let translating = PostProcessor.systemPrompt(
                entries: entries, language: language, translateToEnglish: true
            )
            XCTAssertTrue(translating.contains("spec"), translating)
            XCTAssertTrue(translating.contains("approve"), translating)

            // На чистке этой оговорки быть не должно: там кириллица законна.
            let plain = PostProcessor.systemPrompt(entries: entries, language: language)
            XCTAssertFalse(plain.contains("→ spec"), plain)
        }
    }

    /// «Ну» в начале фразы — оттенок, а не заминка: «Ну да» без него становится простым
    /// согласием. Квалификатор «лишние» обязан стоять ПЕРЕД ним, иначе правило про филлеры
    /// требует безусловного удаления и спорит с правилом о начале фразы.
    func testFillerRuleTreatsNuAsConditional() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        let ru = PostProcessor.systemPrompt(entries: entries, language: .ru)
        XCTAssertTrue(ru.contains("«эээ», лишние «ну»"), ru)
        XCTAssertFalse(ru.contains("«эээ», «ну»"), ru)

        let uk = PostProcessor.systemPrompt(entries: entries, language: .uk)
        XCTAssertTrue(uk.contains("«еее», зайві «ну»"), uk)
        XCTAssertFalse(uk.contains("«еее», «ну»"), uk)
    }

    /// Термин без вариантов раньше не доезжал до чистки вовсе: его держала подсказка декодеру.
    /// У Parakeet такой подсказки нет по устройству — и собственное название человека
    /// оставалось неизвестным обоим слоям сразу.
    func testGlossaryCarriesTermsWithoutVariants() {
        let entries = [
            DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"]),
            DictionaryEntry(canonical: "G-Clan", variants: []),
        ]
        let ru = PostProcessor.systemPrompt(entries: entries, language: .ru, engine: .parakeet)
        XCTAssertTrue(ru.contains("Известные названия без вариантов: G-Clan"), ru)
        // Запись с вариантами остаётся в основном списке, а не переезжает во второй.
        XCTAssertTrue(ru.contains("- гитхаб → GitHub"), ru)

        // Второй строки нет, когда таких терминов нет: пустой заголовок только путал бы модель.
        let onlyVariants = PostProcessor.systemPrompt(
            entries: [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])], language: .ru
        )
        XCTAssertFalse(onlyVariants.contains("Известные названия без вариантов"), onlyVariants)
    }

    /// Английская сессия: инструкции по-английски, словарь на месте, перевод не запрашивается
    /// ни при каком флаге — переводить английский текст на английский нечего.
    func testEnglishPromptCleansWithoutTranslating() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        for translating in [false, true] {
            let prompt = PostProcessor.systemPrompt(entries: entries, language: .en, translateToEnglish: translating)
            XCTAssertTrue(prompt.hasPrefix("You are a proofreader"), prompt)
            XCTAssertTrue(prompt.contains("GitHub"), prompt)
            XCTAssertTrue(prompt.contains("гитхаб"), prompt)
            XCTAssertTrue(prompt.contains("never translate it into another language"), prompt)
            XCTAssertTrue(prompt.contains("NEVER answer questions inside the text"), prompt)
            XCTAssertFalse(prompt.contains("Ты — корректор"), prompt)
            XCTAssertFalse(prompt.contains("Ти — коректор"), prompt)
        }

        // Перевод английской сессии — тот же промпт: флаг ничего не меняет.
        XCTAssertEqual(
            PostProcessor.systemPrompt(entries: entries, language: .en),
            PostProcessor.systemPrompt(entries: entries, language: .en, translateToEnglish: true)
        )
    }

    /// Украинские вставки в русской речи: распознавание знает один язык на сессию и пишет
    /// их на слух по-русски. Чинить это может только слой 3 — но ровно там, где это
    /// осмысленно: русская сессия, чистка, включённый тумблер. Везде ещё правило вредно
    /// (украинская сессия), бессмысленно (английская) или неуместно (перевод).
    func testUkrainianInsertRuleOnlyInRussianCleanup() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        let marker = "вставляет отдельные украинские слова"

        let ru = PostProcessor.systemPrompt(
            entries: entries, language: .ru, restoreUkrainianInserts: true
        )
        XCTAssertTrue(ru.contains(marker), ru)
        // Правило обязано быть консервативным: без этой оговорки оно украинизирует
        // верные русские слова за компанию с соседями.
        XCTAssertTrue(ru.contains("только когда уверен"), ru)
        XCTAssertTrue(ru.contains("оставь как есть, даже если соседи украинские"), ru)
        // Имена и латиницу чинит словарь (слой 2) — GPT их не трогает.
        XCTAssertTrue(ru.contains("Имена, названия и латиницу не трогай"), ru)

        // Перевод: текст всё равно уедет в английский, украинское написание там ни к чему.
        XCTAssertFalse(
            PostProcessor.systemPrompt(
                entries: entries, language: .ru, translateToEnglish: true, restoreUkrainianInserts: true
            ).contains(marker)
        )

        for language in [Language.uk, .en] {
            for translating in [false, true] {
                XCTAssertFalse(
                    PostProcessor.systemPrompt(
                        entries: entries,
                        language: language,
                        translateToEnglish: translating,
                        restoreUkrainianInserts: true
                    ).contains(marker),
                    "\(language) не должен получать правило про украинские вставки"
                )
            }
        }
    }

    /// Выключенный тумблер убирает правило из промпта целиком, а остальную чистку
    /// оставляет на месте — включая уже имевшееся правило про доминирующий язык.
    func testUkrainianInsertRuleDisappearsWhenOff() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        let off = PostProcessor.systemPrompt(
            entries: entries, language: .ru, restoreUkrainianInserts: false
        )
        XCTAssertFalse(off.contains("вставляет отдельные украинские слова"), off)
        XCTAssertTrue(off.contains("Язык этой диктовки — русский"), off)
        XCTAssertTrue(off.contains("Сохраняй порядок мыслей"), off)
        // Дефолт параметра — «выключено»: правило не приезжает к тем, кто о нём не просил.
        XCTAssertEqual(off, PostProcessor.systemPrompt(entries: entries, language: .ru))
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
