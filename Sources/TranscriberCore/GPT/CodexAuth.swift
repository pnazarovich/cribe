import Foundation

// MARK: - Модели

public struct CodexTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var idToken: String?
    public var accountId: String
    public var lastRefresh: Date

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String? = nil,
        accountId: String,
        lastRefresh: Date = Date()
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
    }
}

public struct DeviceFlowSession: Sendable {
    public let userCode: String
    public let verificationURL: URL
    public let deviceAuthId: String
    public let interval: TimeInterval

    public init(userCode: String, verificationURL: URL, deviceAuthId: String, interval: TimeInterval) {
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.deviceAuthId = deviceAuthId
        self.interval = interval
    }
}

public enum CodexAuthError: LocalizedError, Sendable {
    /// HTTP 404 на usercode — device-code auth выключен в настройках ChatGPT.
    case deviceCodeDisabled
    case notAuthorized
    case reauthRequired(String)
    case timedOut
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .deviceCodeDisabled:
            return "Включите «Device code authentication» в настройках безопасности ChatGPT и повторите вход."
        case .notAuthorized:
            return "Нет авторизации ChatGPT. Войдите в настройках приложения."
        case .reauthRequired(let reason):
            return "Сессия ChatGPT недействительна (\(reason)). Переавторизуйтесь."
        case .timedOut:
            return "Время ожидания подтверждения истекло. Начните вход заново."
        case .server(let message):
            return message
        }
    }
}

// MARK: - Чистый разбор протокола (тестируется без сети)

enum CodexProtocol {
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let defaultPollInterval: TimeInterval = 5
    static let pollDeadline: TimeInterval = 15 * 60
    static let refreshLeeway: TimeInterval = 5 * 60

    static let userCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    static let deviceTokenURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    static let oauthTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    static let redirectURI = "https://auth.openai.com/deviceauth/callback"

    /// `interval` приходит строкой (иногда числом) — разбираем оба варианта.
    static func interval(from raw: Any?) -> TimeInterval {
        let value: TimeInterval?
        switch raw {
        case let number as NSNumber: value = number.doubleValue
        case let string as String: value = TimeInterval(string)
        default: value = nil
        }
        guard let value, value > 0 else { return defaultPollInterval }
        return value
    }

    /// Во время поллинга 403/404 означают «пользователь ещё не подтвердил».
    static func isPending(status: Int) -> Bool {
        status == 403 || status == 404
    }

    private static let terminalRefreshMarkers = ["refresh_token_expired", "reused", "invalidated"]

    /// 401 (повторный — решает вызывающий) либо явный маркер в теле ответа.
    static func isTerminalRefreshError(status: Int, body: String) -> Bool {
        if status == 401 { return true }
        let lowered = body.lowercased()
        return terminalRefreshMarkers.contains { lowered.contains($0) }
    }

    // MARK: JWT

    static func payload(ofJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func accountId(fromAccessToken token: String) -> String? {
        let auth = payload(ofJWT: token)?["https://api.openai.com/auth"] as? [String: Any]
        return auth?["chatgpt_account_id"] as? String
    }

    static func expiry(fromAccessToken token: String) -> Date? {
        guard let exp = payload(ofJWT: token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// Проактивное обновление: срок истекает в ближайшие 5 минут (или `exp` не читается).
    static func needsRefresh(accessToken: String) -> Bool {
        guard let expiry = expiry(fromAccessToken: accessToken) else { return true }
        return expiry.timeIntervalSinceNow <= refreshLeeway
    }
}

// MARK: - Актор авторизации

public actor CodexAuth {
    public static let shared = CodexAuth()

    private let account = KeychainStore.codexTokensAccount

    public init() {}

    public func isAuthorized() -> Bool {
        loadTokens() != nil
    }

    public func logout() {
        KeychainStore.delete(account)
    }

    /// Шаг 1: получаем user_code и device_auth_id.
    public func startDeviceFlow() async throws -> DeviceFlowSession {
        let (data, status) = try await postJSON(
            CodexProtocol.userCodeURL,
            body: ["client_id": CodexProtocol.clientId]
        )
        if status == 404 { throw CodexAuthError.deviceCodeDisabled }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.server("Не удалось начать вход (HTTP \(status)): \(preview(data))")
        }
        guard let deviceAuthId = json["device_auth_id"] as? String,
              let userCode = (json["user_code"] as? String) ?? (json["usercode"] as? String)
        else {
            throw CodexAuthError.server("Ответ без device_auth_id/user_code: \(preview(data))")
        }
        return DeviceFlowSession(
            userCode: userCode,
            verificationURL: CodexProtocol.verificationURL,
            deviceAuthId: deviceAuthId,
            interval: CodexProtocol.interval(from: json["interval"])
        )
    }

    /// Шаг 2 + 3: ждём подтверждения, меняем authorization_code на токены и кладём их в Keychain.
    public func pollUntilAuthorized(_ session: DeviceFlowSession) async throws {
        let deadline = Date().addingTimeInterval(CodexProtocol.pollDeadline)

        while Date() < deadline {
            try Task.checkCancellation()
            let (data, status) = try await postJSON(
                CodexProtocol.deviceTokenURL,
                body: ["device_auth_id": session.deviceAuthId, "user_code": session.userCode]
            )

            if CodexProtocol.isPending(status: status) {
                try await Task.sleep(nanoseconds: UInt64(session.interval * 1_000_000_000))
                continue
            }
            guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["authorization_code"] as? String
            else {
                throw CodexAuthError.server("Подтверждение не получено (HTTP \(status)): \(preview(data))")
            }

            try await exchange(code: code, verifier: json["code_verifier"] as? String)
            return
        }
        throw CodexAuthError.timedOut
    }

    /// Действующий access-токен: обновляем проактивно, если до истечения ≤ 5 минут.
    public func validAccessToken() async throws -> (token: String, accountId: String) {
        guard let tokens = loadTokens() else { throw CodexAuthError.notAuthorized }
        guard CodexProtocol.needsRefresh(accessToken: tokens.accessToken) else {
            return (tokens.accessToken, tokens.accountId)
        }
        let refreshed = try await refresh(tokens)
        return (refreshed.accessToken, refreshed.accountId)
    }

    // MARK: - Внутреннее

    private func exchange(code: String, verifier: String?) async throws {
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": CodexProtocol.redirectURI,
            "client_id": CodexProtocol.clientId,
        ]
        if let verifier { form["code_verifier"] = verifier }

        let (data, status) = try await postForm(CodexProtocol.oauthTokenURL, form: form)
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String
        else {
            throw CodexAuthError.server("Обмен кода на токены не удался (HTTP \(status)): \(preview(data))")
        }
        guard let accountId = CodexProtocol.accountId(fromAccessToken: access) else {
            throw CodexAuthError.server("В токене нет chatgpt_account_id.")
        }
        save(CodexTokens(
            accessToken: access,
            refreshToken: refreshToken,
            idToken: json["id_token"] as? String,
            accountId: accountId
        ))
    }

    private func refresh(_ tokens: CodexTokens) async throws -> CodexTokens {
        var lastStatus = 0
        var lastBody = ""

        for attempt in 0..<2 {
            let (data, status) = try await postJSON(CodexProtocol.oauthTokenURL, body: [
                "client_id": CodexProtocol.clientId,
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
            ])
            if status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let access = json["access_token"] as? String {
                // refresh_token ротируется — сохраняем новый, если пришёл.
                let updated = CodexTokens(
                    accessToken: access,
                    refreshToken: (json["refresh_token"] as? String) ?? tokens.refreshToken,
                    idToken: (json["id_token"] as? String) ?? tokens.idToken,
                    accountId: CodexProtocol.accountId(fromAccessToken: access) ?? tokens.accountId
                )
                save(updated)
                return updated
            }

            lastStatus = status
            lastBody = String(decoding: data, as: UTF8.self)
            if CodexProtocol.isTerminalRefreshError(status: status, body: lastBody) {
                // 401 считаем терминальным только при повторе.
                if status == 401 && attempt == 0 { continue }
                logout()
                throw CodexAuthError.reauthRequired("HTTP \(status)")
            }
            break
        }
        throw CodexAuthError.server("Не удалось обновить токен (HTTP \(lastStatus)): \(lastBody.prefix(200))")
    }

    private func loadTokens() -> CodexTokens? {
        guard let data = KeychainStore.get(account) else { return nil }
        return try? JSONDecoder().decode(CodexTokens.self, from: data)
    }

    private func save(_ tokens: CodexTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        KeychainStore.set(data, account: account)
    }

    private func postJSON(_ url: URL, body: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func postForm(_ url: URL, form: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        request.httpBody = Data(encoded.utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func preview(_ data: Data) -> String {
        String(String(decoding: data, as: UTF8.self).prefix(200))
    }
}
