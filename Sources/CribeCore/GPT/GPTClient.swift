import Foundation

// MARK: - Конфигурация

public enum GPTAuthMode: String, Codable, Sendable {
    case apiKey
    case codex
}

public struct GPTConfig: Sendable {
    public var mode: GPTAuthMode
    public var model: String
    /// "none" | "minimal" | "low" | "medium" | "high"
    public var effort: String

    public static let defaultEffort = "low"

    /// Модель у обоих бэкендов одна и выбрана замером, а не вкусом.
    ///
    /// Замер 2026-10-18: 144 вызова, 18 своих записей по два прогона, четыре модели.
    /// `gpt-6-sol` против прежней `gpt-5.6-terra`: медиана 2,0 с против 2,4, худший вызов
    /// 2,7 с против 4,9 (для срока попытки это главное), два прогона одного текста совпали
    /// в 15 случаях из 18 против 11, а к тому, что вставлялось раньше, она даже ближе.
    /// `gpt-6-luna` быстрее всех (1,6 с), но совпала с собой лишь в 8 из 18 — для чистки
    /// разброс хуже скорости. И главное: каталог Codex помечает terra «старой» и называет
    /// sol её заменой, а `gpt-5.5` на этом пути отключили 2026-10-14 без предупреждения —
    /// оставаться на уходящей модели значит ждать того же.
    ///
    /// Остаётся полем `model`, а не константой в клиенте, чтобы CLI мог подставить другую
    /// ради следующего такого замера.
    public static let defaultModel = "gpt-6-sol"

    public init(mode: GPTAuthMode = .codex, model: String? = nil, effort: String = GPTConfig.defaultEffort) {
        self.mode = mode
        self.model = model ?? GPTConfig.defaultModel
        self.effort = effort
    }
}

public enum GPTClientError: LocalizedError, Sendable {
    case missingAPIKey
    case http(Int, String)
    /// `code` — машинный код из кадра ошибки (`server_error`, `usage_limit_reached`…):
    /// по нему решается, есть ли смысл повторять. Текст для этого не годится.
    case stream(String, code: String? = nil)
    case empty

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Не задан API-ключ OpenAI. Добавьте его в настройках."
        case .http(let status, let body):
            return "Запрос к модели не удался (HTTP \(status)): \(body.prefix(200))"
        case .stream(let message, _):
            return "Модель вернула ошибку: \(message)"
        case .empty:
            return "Модель вернула пустой ответ."
        }
    }
}

// MARK: - Чистая часть протокола (тестируется без сети)

enum GPTProtocol {
    /// Версия официального клиента, которой мы представляемся. От неё зависит, какие модели
    /// бэкенд вообще покажет: с 0.146.0 список кончался на `gpt-5.6-*`, а `gpt-6-*` требуют
    /// не ниже 0.155.0. Проверено запросом 2026-10-18.
    static let clientVersion = "0.163.0"
    static let userAgent = "codex_cli_rs/\(clientVersion) (Mac OS 26.5.1; arm64) Terminal"
    static let originator = "codex_cli_rs"

    static let codexResponsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let codexModelsURL = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=\(clientVersion)")!
    static let apiResponsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let apiModelsURL = URL(string: "https://api.openai.com/v1/models")!

    static let fallbackModels = ["gpt-5.2", "gpt-5.5", "gpt-5.6-terra", "gpt-5.6-luna"]

    /// Codex-бэкенд не принимает `minimal`/`none` — нормализуем в `low`.
    static func normalizedEffort(_ effort: String, mode: GPTAuthMode) -> String {
        guard mode == .codex, effort == "minimal" || effort == "none" else { return effort }
        return "low"
    }

    /// Reasoning-поля понимает не всякая модель: публичный API отвечает 400 на `reasoning`
    /// и `include: ["reasoning.encrypted_content"]` для gpt-4o и прочих не-reasoning семейств.
    /// Codex-бэкенд отдаёт только reasoning-модели, поэтому там проверка по слагу не нужна.
    ///
    /// Семейство `gpt-6` — тоже с рассуждением. Без него переход на `gpt-6-sol` молча
    /// выкидывал из запроса усилие на пути с API-ключом: модель работала с серверным
    /// усилием по умолчанию, а не с замеренными `low` и `medium`.
    static func supportsReasoning(model: String, mode: GPTAuthMode) -> Bool {
        mode == .codex || model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6")
    }

    static func requestBody(
        model: String,
        instructions: String,
        input: String,
        effort: String,
        mode: GPTAuthMode,
        promptCacheKey: String? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [[
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": input]],
            ]],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
        ]
        // Официальный клиент Codex шлёт ключ кэша, равный заголовку `session-id`: по нему
        // сервер решает, куда положить разобранный префикс промпта. Без него наш промпт
        // в 14 КБ каждый раз разбирался заново.
        if let promptCacheKey { body["prompt_cache_key"] = promptCacheKey }
        // `none` означает «без reasoning вовсе» — тогда обоих полей в теле быть не должно.
        let effort = normalizedEffort(effort, mode: mode)
        if effort != "none", supportsReasoning(model: model, mode: mode) {
            body["reasoning"] = ["effort": effort]
            body["include"] = ["reasoning.encrypted_content"]
        }
        return body
    }

    static func codexModels(from data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = json?["models"] as? [[String: Any]] ?? []
        return models
            .filter { $0["visibility"] as? String == "list" }
            .compactMap { $0["slug"] as? String }
    }

    static func apiModels(from data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = json?["data"] as? [[String: Any]] ?? []
        return models
            .filter { ($0["id"] as? String)?.hasPrefix("gpt-") == true }
            .sorted { ($0["created"] as? NSNumber)?.doubleValue ?? 0 > ($1["created"] as? NSNumber)?.doubleValue ?? 0 }
            .compactMap { $0["id"] as? String }
    }
}

/// Накопитель SSE: `data:`-строки → текст ответа.
struct SSEAccumulator {
    private(set) var text = ""
    private(set) var isCompleted = false

    mutating func consume(_ line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "response.output_text.delta":
            if let delta = json["delta"] as? String { text += delta }
        case "response.completed":
            isCompleted = true
        case "response.failed":
            throw GPTClientError.stream(Self.message(in: json) ?? "неизвестная ошибка", code: Self.code(in: json))
        case "error":
            // Верхнеуровневый кадр ошибки: лимиты аккаунта, 429 внутри стрима.
            throw GPTClientError.stream(Self.message(in: json) ?? "неизвестная ошибка", code: Self.code(in: json))
        case "response.incomplete":
            // Ответ оборван на полуслове. Раньше этот кадр проходил мимо: поток просто
            // заканчивался, и накопленный ОБРЫВОК уезжал в поле как готовая чистка.
            // Человек получал половину своей диктовки и не знал об этом.
            let details = (json["response"] as? [String: Any])?["incomplete_details"] as? [String: Any]
            let reason = details?["reason"] as? String
            throw GPTClientError.stream("ответ оборван" + (reason.map { " (\($0))" } ?? ""), code: "incomplete")
        default:
            // Прочие error-подобные кадры не глушим, иначе причина подменится «пустым ответом».
            if type.lowercased().contains("error") {
                throw GPTClientError.stream(
                    Self.message(in: json).map { "\(type): \($0)" } ?? type,
                    code: Self.code(in: json)
                )
            }
        }
    }

    /// Итог потока — только если он завершён.
    ///
    /// Поток, закрытый сервером без `response.completed`, раньше считался ответом:
    /// цикл чтения просто кончался, и накопленный обрывок уезжал в поле как вся чистка
    /// или весь перевод — без повтора и без плашки. Официальный клиент Codex считает
    /// такой поток отдельной ошибкой и повторяет запрос; мы — тоже (см. `isRetryable`).
    func result() throws -> String {
        guard isCompleted else { throw GPTClientError.stream("поток закрыт до response.completed") }
        guard !text.isEmpty else { throw GPTClientError.empty }
        return text
    }

    /// Код ошибки лежит там же, где и сообщение.
    static func code(in json: [String: Any]) -> String? {
        if let code = json["code"] as? String { return code }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String { return code }
        let responseError = (json["response"] as? [String: Any])?["error"] as? [String: Any]
        return responseError?["code"] as? String
    }

    /// Сообщение об ошибке лежит по-разному: верхним уровнем, в `error` или в `response.error`.
    private static func message(in json: [String: Any]) -> String? {
        if let message = json["message"] as? String { return message }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String { return message }
        let responseError = (json["response"] as? [String: Any])?["error"] as? [String: Any]
        return responseError?["message"] as? String
    }
}

// MARK: - Клиент

public actor GPTClient {
    private let config: GPTConfig
    private let sessionId = UUID().uuidString

    public init(config: GPTConfig) {
        self.config = config
    }

    public func listModels() async throws -> [String] {
        do {
            switch config.mode {
            case .codex:
                var request = URLRequest(url: GPTProtocol.codexModelsURL)
                try await applyCodexHeaders(&request, accept: "application/json", session: sessionId)
                let (data, status) = try await fetch(request)
                guard status == 200 else { throw GPTClientError.http(status, String(decoding: data, as: UTF8.self)) }
                let models = try GPTProtocol.codexModels(from: data)
                return models.isEmpty ? GPTProtocol.fallbackModels : models

            case .apiKey:
                var request = URLRequest(url: GPTProtocol.apiModelsURL)
                try applyAPIKeyHeaders(&request, accept: "application/json")
                let (data, status) = try await fetch(request)
                guard status == 200 else { throw GPTClientError.http(status, String(decoding: data, as: UTF8.self)) }
                let models = try GPTProtocol.apiModels(from: data)
                return models.isEmpty ? GPTProtocol.fallbackModels : models
            }
        } catch {
            return GPTProtocol.fallbackModels
        }
    }

    /// Прогрев соединения: лёгкий GET к списку моделей текущего режима, результат выбрасывается.
    /// Смысл только в побочном эффекте — TCP + TLS + HTTP/2 к хосту уже установлены к моменту,
    /// когда конвейеру понадобится POST чистки (это ~200–400 мс рукопожатий).
    /// Ничего не бросает и ничего не меняет: провал прогрева означает лишь холодное соединение.
    public func prewarm() async {
        do {
            var request = URLRequest(
                url: config.mode == .codex ? GPTProtocol.codexModelsURL : GPTProtocol.apiModelsURL,
                timeoutInterval: 5
            )
            switch config.mode {
            case .codex: try await applyCodexHeaders(&request, accept: "application/json", session: sessionId)
            case .apiKey: try applyAPIKeyHeaders(&request, accept: "application/json")
            }
            _ = try await URLSession.shared.data(for: request)
        } catch {
            // Нечего логировать: прогрев необязателен, а реальный запрос сам сообщит о проблеме.
        }
    }

    /// - Parameters:
    ///   - cacheKey: устойчивый ключ кэша промпта — уходит и в тело, и в `session-id`.
    ///     Нет ключа — сессия своя у каждого клиента, как было.
    ///   - onFirstText: зовётся один раз, когда приехал первый кусок текста ответа. Нужен
    ///     журналу: без него не отличить «модель долго думала» от «долго писала».
    public func respond(
        instructions: String,
        input: String,
        cacheKey: String? = nil,
        onFirstText: (@Sendable () -> Void)? = nil
    ) async throws -> String {
        var request = URLRequest(
            url: config.mode == .codex ? GPTProtocol.codexResponsesURL : GPTProtocol.apiResponsesURL
        )
        request.httpMethod = "POST"
        switch config.mode {
        case .codex: try await applyCodexHeaders(&request, accept: "text/event-stream", session: cacheKey ?? sessionId)
        case .apiKey: try applyAPIKeyHeaders(&request, accept: "text/event-stream")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: GPTProtocol.requestBody(
            model: config.model,
            instructions: instructions,
            input: input,
            effort: config.effort,
            mode: config.mode,
            promptCacheKey: cacheKey
        ))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 500 { break }
            }
            throw GPTClientError.http(status, body)
        }

        var accumulator = SSEAccumulator()
        for try await line in bytes.lines {
            let hadText = !accumulator.text.isEmpty
            try accumulator.consume(line)
            if !hadText, !accumulator.text.isEmpty { onFirstText?() }
            if accumulator.isCompleted { break }
        }
        return try accumulator.result()
    }

    // MARK: - Заголовки и транспорт

    private func applyCodexHeaders(_ request: inout URLRequest, accept: String, session: String) async throws {
        let (token, accountId) = try await CodexAuth.shared.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(GPTProtocol.originator, forHTTPHeaderField: "originator")
        request.setValue(GPTProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(session, forHTTPHeaderField: "session-id")
        request.setValue(accept, forHTTPHeaderField: "accept")
    }

    private func applyAPIKeyHeaders(_ request: inout URLRequest, accept: String) throws {
        guard let key = SecretStore.getString(SecretStore.apiKeyAccount), !key.isEmpty else {
            throw GPTClientError.missingAPIKey
        }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "accept")
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
