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

    public static func defaultModel(for mode: GPTAuthMode) -> String {
        mode == .codex ? "gpt-5.2" : "gpt-5.6-luna"
    }

    public init(mode: GPTAuthMode = .codex, model: String? = nil, effort: String = GPTConfig.defaultEffort) {
        self.mode = mode
        self.model = model ?? GPTConfig.defaultModel(for: mode)
        self.effort = effort
    }
}

public enum GPTClientError: LocalizedError, Sendable {
    case missingAPIKey
    case http(Int, String)
    case stream(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Не задан API-ключ OpenAI. Добавьте его в настройках."
        case .http(let status, let body):
            return "Запрос к модели не удался (HTTP \(status)): \(body.prefix(200))"
        case .stream(let message):
            return "Модель вернула ошибку: \(message)"
        case .empty:
            return "Модель вернула пустой ответ."
        }
    }
}

// MARK: - Чистая часть протокола (тестируется без сети)

enum GPTProtocol {
    static let clientVersion = "0.146.0"
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
    static func supportsReasoning(model: String, mode: GPTAuthMode) -> Bool {
        mode == .codex || model.hasPrefix("gpt-5")
    }

    static func requestBody(
        model: String,
        instructions: String,
        input: String,
        effort: String,
        mode: GPTAuthMode
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
            throw GPTClientError.stream(Self.message(in: json) ?? "неизвестная ошибка")
        case "error":
            // Верхнеуровневый кадр ошибки: лимиты аккаунта, 429 внутри стрима.
            throw GPTClientError.stream(Self.message(in: json) ?? "неизвестная ошибка")
        default:
            // Прочие error-подобные кадры не глушим, иначе причина подменится «пустым ответом».
            if type.lowercased().contains("error") {
                throw GPTClientError.stream(Self.message(in: json).map { "\(type): \($0)" } ?? type)
            }
        }
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
                try await applyCodexHeaders(&request, accept: "application/json")
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

    public func respond(instructions: String, input: String) async throws -> String {
        var request = URLRequest(
            url: config.mode == .codex ? GPTProtocol.codexResponsesURL : GPTProtocol.apiResponsesURL
        )
        request.httpMethod = "POST"
        switch config.mode {
        case .codex: try await applyCodexHeaders(&request, accept: "text/event-stream")
        case .apiKey: try applyAPIKeyHeaders(&request, accept: "text/event-stream")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: GPTProtocol.requestBody(
            model: config.model,
            instructions: instructions,
            input: input,
            effort: config.effort,
            mode: config.mode
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
            try accumulator.consume(line)
            if accumulator.isCompleted { break }
        }
        guard !accumulator.text.isEmpty else { throw GPTClientError.empty }
        return accumulator.text
    }

    // MARK: - Заголовки и транспорт

    private func applyCodexHeaders(_ request: inout URLRequest, accept: String) async throws {
        let (token, accountId) = try await CodexAuth.shared.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(GPTProtocol.originator, forHTTPHeaderField: "originator")
        request.setValue(GPTProtocol.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(sessionId, forHTTPHeaderField: "session-id")
        request.setValue(accept, forHTTPHeaderField: "accept")
    }

    private func applyAPIKeyHeaders(_ request: inout URLRequest, accept: String) throws {
        guard let key = KeychainStore.getString(KeychainStore.apiKeyAccount), !key.isEmpty else {
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
