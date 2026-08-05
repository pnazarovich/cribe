import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import TranscriberCore

/// Раздел настроек: строка бокового списка и панель за ней.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case ai
    case translation
    case dictionary
    case about

    /// Идентификатор — сам раздел: выбор в боковом списке привязан к `SettingsPane?`,
    /// а `List` берёт тип выбора из `ID` своих строк.
    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "Общие"
        case .ai: return "AI"
        case .translation: return "Перевод"
        case .dictionary: return "Словарь"
        case .about: return "О программе"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .translation: return "globe"
        case .dictionary: return "text.book.closed"
        case .about: return "info.circle"
        }
    }
}

/// Настройки боковым списком, как в системных: разделов уже пять, и вкладками поверху
/// они переставали читаться с первого взгляда.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let dictionaryURL: URL

    @State private var selection: SettingsPane? = .general

    /// Список моделей и вход в ChatGPT живут выше панелей: панель раздела пересоздаётся на
    /// каждом переключении, а загруженный список и идущий device-code этого пережить
    /// обязаны — иначе вход обрывался бы щелчком по соседней строке.
    @StateObject private var models = ModelListModel()
    @StateObject private var codex = CodexAuthModel()

    private var pane: SettingsPane { selection ?? .general }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.icon)
            }
            // Ширина под самую длинную строку («О программе»). Кнопку сворачивания списка
            // тут не убираем: без неё `NavigationSplitView` перестаёт слушать и эту ширину,
            // сам сжимает список до ~155 pt и обрезает подписи — проверено.
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            detail.navigationTitle(pane.title)
        }
        // `.balanced` держит боковой список на месте: сворачивать его в окне на пять
        // разделов незачем — заодно и кнопка сворачивания в тулбаре лишняя.
        .navigationSplitViewStyle(.balanced)
        // Высоту и нижние границы задаём сами; ширину окна `NavigationSplitView` берёт по
        // своей колонке детали (~720 pt + список слева) и внешним `idealWidth` не двигается —
        // проверено на чистом домене настроек. Окно остаётся тянущимся в обе стороны.
        .frame(
            minWidth: 640, maxWidth: .infinity,
            minHeight: 520, maxHeight: .infinity
        )
        // Поллинг device-code живёт до 15 минут — закрытые настройки не должны
        // продолжать долбить auth.openai.com каждые пять секунд.
        .onDisappear { codex.cancel() }
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralPane(settings: settings)
        case .ai: AIPane(settings: settings, models: models, codex: codex)
        case .translation: TranslationPane(settings: settings, models: models)
        case .dictionary: DictionaryPane(url: dictionaryURL)
        case .about: AboutPane()
        }
    }
}

// MARK: - Общие

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchNote: String?
    @State private var accessibilityGranted = TextInserter.hasAccessibility

    var body: some View {
        Form {
            Section {
                Picker("Кнопка записи:", selection: $settings.dictationHotkeyMode) {
                    Text("Правый ⌘").tag(HotkeyMode.rightCommand)
                    Text("Свой шорткат").tag(HotkeyMode.custom)
                }

                switch settings.dictationHotkeyMode {
                case .rightCommand:
                    EmptyView()
                case .custom:
                    KeyboardShortcuts.Recorder("Диктовка:", name: .toggleDictation)
                    KeyboardShortcuts.Recorder("Диктовка с переводом:", name: .toggleTranslateDictation)
                }

                KeyboardShortcuts.Recorder("Сменить язык:", name: .switchLanguage)
            } header: {
                Text("Запись")
            } footer: {
                switch settings.dictationHotkeyMode {
                case .rightCommand:
                    caption(
                        accessibilityGranted
                            ? "Правый ⌥ — диктовка с переводом на английский. Esc отменяет запись."
                            : "Правый ⌥ — диктовка с переводом на английский. "
                                + "Нужно разрешение Accessibility."
                    )
                case .custom:
                    caption("Esc отменяет запись в любом режиме.")
                }
            }

            Section {
                Picker("Язык:", selection: $settings.language) {
                    ForEach(Language.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Toggle("Смешанная речь (RU + UK)", isOn: $settings.mixedSpeech)
                Toggle("Автостоп по тишине (2 с)", isOn: $settings.autoStopEnabled)
            } header: {
                Text("Распознавание")
            } footer: {
                caption(
                    "Смешанная речь подсказывает распознаванию украинские слова внутри "
                        + "русской диктовки. На скорость не влияет."
                )
            }

            Section {
                Toggle("Карточки, если нет поля ввода", isOn: $settings.cardsWhenNoField)
            } header: {
                Text("Вставка")
            } footer: {
                caption(
                    "Текст покажется карточкой внизу слева — её можно перетащить в любое поле. "
                        + "Выключено: Cmd-V уходит в приложение всегда."
                )
            }

            Section {
                Toggle("Звуки старта и окончания записи", isOn: $settings.soundsEnabled)

                // Тумблер ведомый: значение меняем только после успешного вызова SMAppService,
                // иначе галочка врала бы о фактическом состоянии.
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
            } header: {
                Text("Приложение")
            } footer: {
                if let launchNote {
                    caption(launchNote)
                }
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

private struct AIPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelListModel
    @ObservedObject var codex: CodexAuthModel

    @State private var apiKey = ""
    @State private var apiKeyNote: String?

    var body: some View {
        Form {
            Section {
                Toggle("AI-чистка (GPT)", isOn: $settings.gptEnabled)
                Toggle("Короткие диктовки — без GPT", isOn: $settings.skipGPTForShort)
                if settings.skipGPTForShort {
                    Stepper(
                        "до \(settings.shortDictationWordLimit) слов",
                        value: $settings.shortDictationWordLimit,
                        in: 1...30
                    )
                }
            } header: {
                Text("Чистка речи")
            } footer: {
                caption(
                    "GPT расставляет знаки, убирает слова-паразиты и держит термины словаря. "
                        + "На «ок» и «да, давай» чистить нечего — целый круг к модели там лишний."
                )
            }

            Section {
                Picker("Доступ:", selection: $settings.gptMode) {
                    Text("Аккаунт ChatGPT").tag(GPTAuthMode.codex)
                    Text("API-ключ OpenAI").tag(GPTAuthMode.apiKey)
                }
                .onChange(of: settings.gptMode) { _, mode in
                    // Списки моделей у бэкендов разные: старый выбор в новом режиме не существует.
                    models.clear()
                    settings.gptModel = GPTConfig.defaultModel(for: mode)
                    // Уход в режим API-ключа прячет блок входа — поллинг за ним не оставляем.
                    codex.cancel()
                }

                switch settings.gptMode {
                case .apiKey: apiKeySection
                case .codex: codexSection
                }
            } header: {
                Text("Доступ к модели")
            } footer: {
                caption("Ключ хранится в Keychain, вход в ChatGPT — там же. В файлы ничего не пишется.")
            }

            Section {
                ModelRow(models: models, selection: $settings.gptModel, config: settings.gptConfig)
                EffortPicker(selection: $settings.gptEffort)
            } header: {
                Text("Модель чистки")
            }

            Section {
                RecommendationCards(
                    mode: settings.gptMode,
                    model: $settings.gptModel,
                    effort: $settings.gptEffort
                )
            } header: {
                Text("Рекомендации")
            } footer: {
                caption(ModelRecommendations.disclaimer)
            }
        }
        .formStyle(.grouped)
        .task {
            apiKey = KeychainStore.getString(KeychainStore.apiKeyAccount) ?? ""
            await codex.refreshStatus()
        }
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
                Label("Авторизован", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
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

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Перевод

/// Перевод — отдельный вызов и другая нагрузка, чем простая чистка: ему и модель нужна
/// своя (чистке обычно хватает самой быстрой), поэтому и раздел свой.
private struct TranslationPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelListModel

    var body: some View {
        Form {
            Section {
                Toggle("Перевод на английский", isOn: $settings.translateToEnglish)
            } header: {
                Text("Когда переводить")
            } footer: {
                caption(
                    "Правый ⌥ переводит одну диктовку даже с выключенным тумблером — "
                        + "включать его ради одной фразы не нужно."
                )
            }

            Section {
                ModelRow(models: models, selection: $settings.translateModel, config: settings.gptConfig)
                EffortPicker(selection: $settings.translateEffort)
            } header: {
                Text("Модель перевода")
            } footer: {
                caption("Тот же вызов и чистит, и переводит — модель покрупнее здесь окупается.")
            }

            Section {
                RecommendationCards(
                    mode: settings.gptMode,
                    model: $settings.translateModel,
                    effort: $settings.translateEffort
                )
            } header: {
                Text("Рекомендации")
            } footer: {
                caption(ModelRecommendations.disclaimer)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Словарь

private struct DictionaryPane: View {
    let url: URL

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Button("Открыть редактор словаря…") {
                    WindowPresenter.shared.present { openWindow(id: WindowID.dictionary) }
                }
            } header: {
                Text("Редактор")
            } footer: {
                caption(
                    "Термины словаря подсказываются Whisper, дожимаются локальными правилами "
                        + "с учётом падежей и закрепляются GPT-проходом."
                )
            }

            Section {
                Text(url.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } header: {
                Text("Файл словаря")
            } footer: {
                caption("Обычный JSON: правки снаружи приложение подхватывает само.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - О программе

private struct AboutPane: View {
    private static let repository = URL(string: "https://github.com/pnazarovich/transcriber")!

    private static let credits: [(name: String, role: String, url: URL)] = [
        (
            "WhisperKit",
            "распознавание речи на Neural Engine",
            URL(string: "https://github.com/argmaxinc/WhisperKit")!
        ),
        (
            "FluidAudio",
            "определение речи и тишины",
            URL(string: "https://github.com/FluidInference/FluidAudio")!
        ),
        (
            "KeyboardShortcuts",
            "глобальные сочетания клавиш",
            URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!
        ),
    ]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcriber").font(.title2.weight(.semibold))
                        Text("Версия \(Self.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Link("github.com/pnazarovich/transcriber", destination: Self.repository)
                            .font(.callout)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            } footer: {
                caption(
                    "Локальная диктовка на русском и украинском: правый ⌘ — говорите, "
                        + "и текст появляется в поле ввода. Речь распознаётся на самом Mac."
                )
            }

            Section {
                ForEach(Self.credits, id: \.name) { credit in
                    HStack(alignment: .firstTextBaseline) {
                        Link(credit.name, destination: credit.url)
                        Text(credit.role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                }
            } header: {
                Text("Открытый код")
            } footer: {
                caption("Сам Transcriber — под лицензией MIT.")
            }
        }
        .formStyle(.grouped)
    }

    /// Версия из Info.plist. В сборке из SwiftPM (без бандла) ключей нет — тогда прочерк.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }
}

// MARK: - Общие детали

/// Пояснение под секцией: один стиль на все разделы.
private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

/// Список моделей бэкенда: общий для чистки и перевода и потому живущий выше панелей.
@MainActor
private final class ModelListModel: ObservableObject {
    @Published private(set) var models: [String] = []
    @Published private(set) var isLoading = false

    func refresh(config: GPTConfig) async {
        isLoading = true
        defer { isLoading = false }
        models = (try? await GPTClient(config: config).listModels()) ?? []
    }

    func clear() {
        models = []
    }

    /// Сохранённая модель может отсутствовать в свежем списке — иначе пикер показал бы пустоту.
    func options(selected: String) -> [String] {
        models.contains(selected) ? models : [selected] + models
    }
}

/// Пикер модели с кнопкой обновления списка.
private struct ModelRow: View {
    @ObservedObject var models: ModelListModel
    @Binding var selection: String
    let config: GPTConfig

    var body: some View {
        HStack {
            Picker("Модель:", selection: $selection) {
                ForEach(models.options(selected: selection), id: \.self) { Text($0).tag($0) }
            }
            if models.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await models.refresh(config: config) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Обновить список моделей")
            }
        }
    }
}

/// Порядок как в спеке; Codex-бэкенд нормализует `none`/`minimal` в `low` сам.
private struct EffortPicker: View {
    @Binding var selection: String

    private static let efforts = ["none", "minimal", "low", "medium", "high"]

    var body: some View {
        Picker("Усилие рассуждения:", selection: $selection) {
            ForEach(Self.efforts, id: \.self) { Text($0).tag($0) }
        }
    }
}

/// Рекомендации тремя карточками в ряд: ⚡ / ⚖️ / 💎. Щелчок по карточке ставит и модель,
/// и усилие — пара всегда применяется целиком, порознь она ничего не значит.
/// Строки пересобираются из режима доступа: у режимов разные усилия и пояснения. Таблица
/// одна и та же и для чистки, и для перевода — ведёт она ту пару, которую ей передали.
private struct RecommendationCards: View {
    let mode: GPTAuthMode
    @Binding var model: String
    @Binding var effort: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(ModelRecommendations.list(for: mode)) { recommendation in
                card(recommendation)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ recommendation: ModelRecommendation) -> some View {
        let isSelected = model == recommendation.model

        return Button {
            model = recommendation.model
            effort = recommendation.effort
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(recommendation.tier.emoji)
                    Text(recommendation.tier.title).font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    // Выбранной модели кнопка не нужна — вместо неё галочка.
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(recommendation.model)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(recommendation.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(
            isSelected
                ? "Уже выбрана"
                : "Выбрать \(recommendation.model), усилие \(recommendation.effort)"
        )
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
