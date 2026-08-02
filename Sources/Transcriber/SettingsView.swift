import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import TranscriberCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let dictionaryURL: URL

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("Общие", systemImage: "gearshape") }
            AITab(settings: settings)
                .tabItem { Label("AI", systemImage: "sparkles") }
            DictionaryTab(url: dictionaryURL)
                .tabItem { Label("Словарь", systemImage: "text.book.closed") }
        }
        .frame(width: 480, height: 430)
    }
}

// MARK: - Общие

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchNote: String?
    @State private var accessibilityGranted = TextInserter.hasAccessibility

    var body: some View {
        Form {
            Picker("Кнопка записи:", selection: $settings.dictationHotkeyMode) {
                Text("Правый ⌘").tag(HotkeyMode.rightCommand)
                Text("Свой шорткат").tag(HotkeyMode.custom)
            }

            switch settings.dictationHotkeyMode {
            case .rightCommand:
                Text("Правый ⌥ — диктовка с переводом на английский")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !accessibilityGranted {
                    Text("Нужно разрешение Accessibility")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .custom:
                KeyboardShortcuts.Recorder("Диктовка:", name: .toggleDictation)
                KeyboardShortcuts.Recorder("Диктовка с переводом:", name: .toggleTranslateDictation)
            }

            KeyboardShortcuts.Recorder("Сменить язык:", name: .switchLanguage)

            Picker("Язык:", selection: $settings.language) {
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }

            Toggle("Автостоп по тишине (2 с)", isOn: $settings.autoStopEnabled)

            Toggle("Карточки, если нет поля ввода", isOn: $settings.cardsWhenNoField)
            Text("Текст покажется карточкой внизу слева — её можно перетащить в любое поле. "
                 + "Выключено: Cmd-V уходит в приложение всегда.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Звуки старта и окончания записи", isOn: $settings.soundsEnabled)

            // Тумблер ведомый: значение меняем только после успешного вызова SMAppService,
            // иначе галочка врала бы о фактическом состоянии.
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))

            if let launchNote {
                Text(launchNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            syncLaunchState()
            // Разрешение выдают в системном окне — при возврате в настройки перечитываем.
            accessibilityGranted = TextInserter.hasAccessibility
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            syncLaunchState()
        } catch {
            launchNote = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func syncLaunchState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchNote = status == .requiresApproval
            ? "Разрешите Transcriber в «Основные → Объекты входа»."
            : nil
    }
}

// MARK: - AI

private struct AITab: View {
    @ObservedObject var settings: AppSettings

    @StateObject private var codex = CodexAuthModel()
    @State private var apiKey = ""
    @State private var apiKeyNote: String?
    @State private var models: [String] = []
    @State private var isLoadingModels = false

    /// Порядок как в спеке; Codex-бэкенд нормализует `none`/`minimal` в `low` сам.
    private static let efforts = ["none", "minimal", "low", "medium", "high"]

    var body: some View {
        Form {
            Toggle("AI-чистка (GPT)", isOn: $settings.gptEnabled)
            Toggle("Короткие диктовки — без GPT", isOn: $settings.skipGPTForShort)
            if settings.skipGPTForShort {
                Stepper(
                    "до \(settings.shortDictationWordLimit) слов",
                    value: $settings.shortDictationWordLimit,
                    in: 1...30
                )
            }
            Toggle("Перевод на английский", isOn: $settings.translateToEnglish)

            Picker("Доступ:", selection: $settings.gptMode) {
                Text("Аккаунт ChatGPT").tag(GPTAuthMode.codex)
                Text("API-ключ OpenAI").tag(GPTAuthMode.apiKey)
            }
            .onChange(of: settings.gptMode) { _, mode in
                // Списки моделей у бэкендов разные: старый выбор в новом режиме не существует.
                models = []
                settings.gptModel = GPTConfig.defaultModel(for: mode)
                // Уход в режим API-ключа прячет блок входа — поллинг за ним не оставляем.
                codex.cancel()
            }

            switch settings.gptMode {
            case .apiKey: apiKeySection
            case .codex: codexSection
            }

            modelPicker(selection: $settings.gptModel)

            recommendations(model: $settings.gptModel, effort: $settings.gptEffort)

            Picker("Усилие рассуждения:", selection: $settings.gptEffort) {
                ForEach(Self.efforts, id: \.self) { Text($0).tag($0) }
            }

            // Перевод — отдельный вызов и другая нагрузка, чем простая чистка: ему
            // и модель нужна своя (чистке обычно хватает самой быстрой).
            Section("Перевод на английский") {
                modelPicker(selection: $settings.translateModel)

                recommendations(model: $settings.translateModel, effort: $settings.translateEffort)

                Picker("Усилие рассуждения:", selection: $settings.translateEffort) {
                    ForEach(Self.efforts, id: \.self) { Text($0).tag($0) }
                }
            }

            // Оговорка одна на оба блока — таблица рекомендаций у них общая.
            Text(ModelRecommendations.disclaimer)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task {
            apiKey = KeychainStore.getString(KeychainStore.apiKeyAccount) ?? ""
            await codex.refreshStatus()
        }
        // Поллинг device-code живёт до 15 минут — закрытые настройки не должны
        // продолжать долбить auth.openai.com каждые пять секунд.
        .onDisappear { codex.cancel() }
    }

    // MARK: API-ключ

    @ViewBuilder
    private var apiKeySection: some View {
        SecureField("API-ключ:", text: $apiKey)
            .onSubmit { saveAPIKey() }
        HStack {
            Button("Сохранить ключ") { saveAPIKey() }
            if let apiKeyNote {
                Text(apiKeyNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Ключ живёт только в Keychain: ни UserDefaults, ни файлов.
    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(KeychainStore.apiKeyAccount)
            apiKeyNote = "Ключ удалён"
        } else {
            KeychainStore.setString(trimmed, account: KeychainStore.apiKeyAccount)
            apiKeyNote = "Ключ сохранён в Keychain"
        }
    }

    // MARK: Аккаунт ChatGPT

    @ViewBuilder
    private var codexSection: some View {
        if codex.isAuthorized {
            HStack {
                Text("✓ Авторизован")
                Spacer()
                Button("Выйти") { Task { await codex.logout() } }
            }
        } else if let session = codex.session {
            VStack(alignment: .leading, spacing: 8) {
                Text("Код подтверждения:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(session.userCode)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        copy(session.userCode)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Скопировать код")
                }
                Link("Открыть страницу подтверждения", destination: session.verificationURL)
                if codex.isPolling {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Ожидаю подтверждения…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Отмена") { codex.cancel() }
                    }
                }
            }
        } else {
            Button("Авторизоваться") { codex.start() }
        }

        if let message = codex.message {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Рекомендации

    /// Строки пересобираются из `settings.gptMode`: у режимов разные усилия и пояснения.
    /// Ведут они ту пару «модель + усилие», которую им передали, — таблица одна и та же
    /// и для чистки, и для перевода.
    private func recommendations(model: Binding<String>, effort: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Рекомендации").font(.caption).foregroundStyle(.secondary)

            ForEach(ModelRecommendations.list(for: settings.gptMode)) { recommendation in
                recommendationRow(recommendation, model: model, effort: effort)
            }
        }
    }

    private func recommendationRow(
        _ recommendation: ModelRecommendation,
        model: Binding<String>,
        effort: Binding<String>
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(recommendation.tier.emoji)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(recommendation.tier.title)
                    Text(recommendation.model)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(recommendation.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Выбранной модели кнопка не нужна — вместо неё галочка.
            if model.wrappedValue == recommendation.model {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Уже выбрана")
            } else {
                Button("Выбрать") {
                    model.wrappedValue = recommendation.model
                    effort.wrappedValue = recommendation.effort
                }
            }
        }
    }

    // MARK: Модели

    /// Пикер модели с кнопкой обновления списка: список моделей общий для чистки и перевода.
    private func modelPicker(selection: Binding<String>) -> some View {
        HStack {
            Picker("Модель:", selection: selection) {
                ForEach(modelOptions(selected: selection.wrappedValue), id: \.self) { Text($0).tag($0) }
            }
            Button {
                Task { await refreshModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoadingModels)
            .help("Обновить список моделей")
        }
    }

    /// Сохранённая модель может отсутствовать в свежем списке — иначе пикер показал бы пустоту.
    private func modelOptions(selected: String) -> [String] {
        models.contains(selected) ? models : [selected] + models
    }

    private func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        models = (try? await GPTClient(config: settings.gptConfig).listModels()) ?? []
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Device-code flow: старт, ожидание подтверждения, статус. Держит одну задачу поллинга.
@MainActor
private final class CodexAuthModel: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var session: DeviceFlowSession?
    @Published private(set) var isPolling = false
    @Published private(set) var message: String?

    private var task: Task<Void, Never>?
    /// Номер попытки входа: хвост отменённой задачи не должен трогать состояние следующей.
    private var generation = 0

    func refreshStatus() async {
        isAuthorized = await CodexAuth.shared.isAuthorized()
    }

    func start() {
        cancel()
        message = nil
        let generation = self.generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await CodexAuth.shared.startDeviceFlow()
                guard generation == self.generation else { return }
                self.session = session
                isPolling = true

                try await CodexAuth.shared.pollUntilAuthorized(session)
                guard generation == self.generation else { return }
                isAuthorized = true
                message = nil
            } catch {
                guard generation == self.generation else { return }
                // deviceCodeDisabled сам объясняет, что включить в настройках ChatGPT.
                message = Self.isCancellation(error) ? nil : error.localizedDescription
            }
            guard generation == self.generation else { return }
            session = nil
            isPolling = false
        }
    }

    /// Идемпотентна: повторный вызов на уже остановленном входе ничего не меняет.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        session = nil
        isPolling = false
    }

    func logout() async {
        cancel()
        await CodexAuth.shared.logout()
        isAuthorized = false
    }

    /// Отмена — не ошибка: `Task` бросает `CancellationError`, URLSession — `URLError.cancelled`.
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

// MARK: - Словарь

private struct DictionaryTab: View {
    let url: URL

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Button("Открыть редактор словаря…") {
                NSApp.activate()
                openWindow(id: WindowID.dictionary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Файл словаря").font(.caption).foregroundStyle(.secondary)
                Text(url.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .formStyle(.grouped)
    }
}
