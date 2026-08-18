import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI
import CribeCore

/// Раздел настроек: строка бокового списка и панель за ней.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case ai
    case dictionary
    case about

    /// Идентификатор — сам раздел: выбор в боковом списке привязан к `SettingsPane?`,
    /// а `List` берёт тип выбора из `ID` своих строк.
    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "Общие"
        case .ai: return "AI"
        case .dictionary: return "Словарь"
        case .about: return "О программе"
        }
    }

    /// Символы без `.circle`-вариантов: строка списка и так читается контейнером.
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .dictionary: return "text.book.closed"
        case .about: return "info"
        }
    }
}

/// Настройки боковым списком, как в системных: разделов четыре, и вкладками поверху
/// они переставали читаться с первого взгляда.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let dictionaryURL: URL

    @State private var selection: SettingsPane? = .general

    /// Список моделей и вход в ChatGPT живут выше панелей: панель раздела пересоздаётся на
    /// каждом переключении, а загруженный список и идущий device-code этого пережить
    /// обязаны — иначе вход обрывался бы щелчком по соседней строке.
    @StateObject private var codex = CodexAuthModel()

    private var pane: SettingsPane { selection ?? .general }

    var body: some View {
        // Две колонки руками, а не `NavigationSplitView`: тот на macOS 26 рисует сайдбару
        // собственную вставную панель со своим радиусом внутри радиуса окна — «двойной
        // бортик», который Apple откатила в следующем релизе, и погасить его снаружи нечем
        // (ни `scrollContentBackground`, ни `backgroundStyle` до него не достают —
        // проверено). Заодно уходит и кнопка сворачивания: сворачивать список на четыре
        // раздела незачем, а висела она одна в пустом тулбаре.
        HStack(spacing: 0) {
            list
            // Граница колонок — волосяная линия, как и вся глубина в окне: ступень фона
            // плюс hairline, без бортиков и теней.
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Заголовок окна — текущий раздел.
        .navigationTitle(pane.title)
        // Сквозь окно настроек видно рабочий стол. Плашки секций рисует сама `Form`
        // полупрозрачной заливкой — им остаётся только эта подложка (см. `settingsForm`).
        .glassWindow()
        // Границы окна: ширина от нижней планки до чего угодно, высоту при открытии задаёт
        // `idealHeight`. Без него окно тянулось по самой длинной панели и под четырьмя
        // строками списка оставалась пустая треть.
        .frame(
            minWidth: 640, maxWidth: .infinity,
            minHeight: 440, idealHeight: 520, maxHeight: .infinity
        )
        // Поллинг device-code живёт до 15 минут — закрытые настройки не должны
        // продолжать долбить auth.openai.com каждые пять секунд.
        .onDisappear { codex.cancel() }
    }

    /// Боковой список: до краёв окна, без своего фона и без своего радиуса. Фоном ему
    /// служит подложка окна — та же, что и у панели справа.
    private var list: some View {
        List(SettingsPane.allCases, selection: $selection) { row in
            Label {
                Text(row.title)
            } icon: {
                // Иконка цветная и следует за системным акцентом. У выделенной строки
                // тинт снимаем: там заливка акцентом, и акцент по акценту не читается —
                // цвет содержимого выделения система подбирает сама.
                Image(systemName: row.icon)
                    .foregroundStyle(row == selection ? AnyShapeStyle(.foreground)
                                                      : AnyShapeStyle(Color.accentColor))
            }
        }
        // Стиль сайдбара — ради выделения скруглённой заливкой; фон при этом свой.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Ширина под самую длинную строку — «О программе».
        .frame(width: 200)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralPane(settings: settings)
        case .ai: AIPane(settings: settings, codex: codex)
        case .dictionary: DictionaryPane(url: dictionaryURL, settings: settings)
        case .about: AboutPane()
        }
    }
}

// MARK: - Общие

private struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    /// Состояние модели одно на приложение: настройки, онбординг и экран обновления
    /// показывают одну и ту же загрузку.
    @ObservedObject private var install = ModelInstall.shared

    /// Тумблер автопроверки ходит прямо в Sparkle — своего флага у настроек нет.
    @ObservedObject private var updates = UpdateController.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchNote: String?
    @State private var accessibilityGranted = TextInserter.hasAccessibility
    /// Сколько записей лежит на диске прямо сейчас: обещание «предсказуемый объём» стоит
    /// ровно столько, сколько его видно.
    @State private var recordingBytes = RecordingStore.shared.bytesOnDisk()
    /// Веса Whisper, оставшиеся от прежних версий. Ноль — строки нет вовсе.
    @State private var legacyBytes = LegacyWhisperCache.shared.bytesOnDisk()

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
                            ? "Правый ⌥ — диктовка с переводом на \(settings.translationTarget.afterOn). "
                                + "Esc отменяет запись."
                            : "Правый ⌥ — диктовка с переводом на \(settings.translationTarget.afterOn). "
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

                Toggle("Автостоп по тишине (2 с)", isOn: $settings.autoStopEnabled)

                if settings.language != .en {
                    Toggle("Мешаю русский и українську в одной диктовке", isOn: $settings.mixesUkrainian)
                }
            } header: {
                Text("Распознавание")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    caption("Язык диктовки форсируется: распознавание его не угадывает.")
                    caption(
                        "Смешанная речь: распознавание слышит украинские слова верно, а вот "
                            + "AI-чистка без этой галочки переписывает их по-русски — «ще раз» "
                            + "становится «ещё раз». С галочкой она их бережёт и заодно "
                            + "возвращает украинское написание словам, которые распознавание "
                            + "записало на слух по-русски («требо» → «треба»). Выключите, если "
                            + "диктуете на одном языке."
                    )
                }
            }

            Section {
                ModelRow(install: install)
                if legacyBytes > 0 {
                    LegacyModelsRow(bytes: $legacyBytes)
                }
            } header: {
                Text("Модель распознавания")
            } footer: {
                caption(
                    "Parakeet TDT v3 от NVIDIA — одна многоязычная модель на все три языка. "
                        + "Качается один раз (~600 МБ) и остаётся в кэше; дальше распознавание "
                        + "идёт без интернета. Английские названия она пишет кириллицей — "
                        + "латиницу им возвращает AI-чистка, поэтому через неё идёт каждая "
                        + "диктовка, даже однословная."
                )
            }

            Section {
                Picker("Хранить записи:", selection: $settings.keptRecordings) {
                    Text("Не хранить").tag(0)
                    Text("Последнюю").tag(1)
                    Text("Три последних").tag(3)
                }

                Button("Стереть записи") {
                    RecordingStore.shared.removeAll()
                    recordingBytes = 0
                }
                .disabled(recordingBytes == 0)
            } header: {
                Text("Записи диктовок")
            } footer: {
                caption(
                    "Звук диктовки остаётся на диске, чтобы потерянную речь можно было "
                        + "распознать заново из «Истории…». Лежит в Application Support → "
                        + "Cribe → recordings, никуда не отправляется. Сейчас занято: "
                        + ByteCountFormatter.string(fromByteCount: recordingBytes, countStyle: .file)
                        + ". Одна запись — не длиннее пяти минут."
                )
            }

            Section {
                PillStyleChooser(selection: $settings.pillStyle)
            } header: {
                Text("Индикатор записи")
            } footer: {
                caption(
                    "Бегущая строка показывает слова по мере речи — для этого приложение "
                        + "перечитывает последние секунды записи примерно раз в секунду. Видно, "
                        + "что распознавание услышало, но батарея расходуется заметнее, поэтому "
                        + "по умолчанию — волна."
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

                Toggle("Проверять обновления автоматически", isOn: $updates.automaticallyChecks)
            } header: {
                Text("Приложение")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let launchNote {
                        caption(launchNote)
                    }
                    caption(
                        "Проверка идёт раз в сутки. Найденное обновление ждёт строкой в меню — "
                            + "окно не открывается поверх работы само."
                    )
                }
            }
        }
        .settingsForm()
        .onAppear {
            syncLaunchState()
            // Разрешение выдают в системном окне — при возврате в настройки перечитываем.
            accessibilityGranted = TextInserter.hasAccessibility
            // Модель могла доехать мимо настроек — например, её дотянула первая диктовка.
            install.refresh()
            recordingBytes = RecordingStore.shared.bytesOnDisk()
            legacyBytes = LegacyWhisperCache.shared.bytesOnDisk()
        }
        // Кольцо укоротили — лишние записи уходят сразу, а не после следующей диктовки:
        // «не хранить» должно означать «уже не хранится».
        .onChange(of: settings.keptRecordings) { _, keeping in
            RecordingStore.shared.prune(keeping: keeping)
            recordingBytes = RecordingStore.shared.bytesOnDisk()
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
            ? "Разрешите Cribe в «Основные → Объекты входа»."
            : nil
    }
}

/// Единственная модель распознавания: её состояние и, если её ещё нет, кнопка «Скачать».
/// Удалить её отсюда нельзя — без неё приложение не работает вовсе, и кнопка «Удалить»
/// означала бы «сломать диктовку».
private struct ModelRow: View {
    @ObservedObject var install: ModelInstall

    var body: some View {
        HStack(spacing: 12) {
            Text("Parakeet TDT v3")
            Spacer(minLength: 8)
            switch install.state {
            case .missing:
                Text("Не скачана · ≈" + Self.size(ModelInstall.approximateBytes))
                    .foregroundStyle(.secondary)
                Button("Скачать") { install.download() }
            case let .downloading(fraction):
                ProgressView(value: fraction).frame(width: 120)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Подготовка…").foregroundStyle(.secondary)
            case .ready:
                Label("Готова", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Text(message).foregroundStyle(.red).lineLimit(2)
                Button("Ещё раз") { install.download() }
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

/// Веса Whisper от прежних версий. Строка появляется, только если они и правда лежат
/// на диске, и исчезает сразу после удаления: место освобождает человек, а не обновление.
private struct LegacyModelsRow: View {
    @Binding var bytes: Int64

    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Старые модели Whisper")
                Spacer(minLength: 8)
                Text(bytes.formatted(.byteCount(style: .file)) + " — не нужны")
                    .foregroundStyle(.secondary)
                Button("Удалить") { confirming = true }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Удалить старые модели Whisper?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) { remove() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(
                "Освободится " + bytes.formatted(.byteCount(style: .file))
                    + ". Распознавание идёт на Parakeet — эти веса больше не используются."
            )
        }
    }

    private func remove() {
        do {
            failure = nil
            try LegacyWhisperCache.shared.remove()
            bytes = 0
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - AI

/// Всё про GPT одним разделом: доступ к модели, чистка и перевод.
///
/// Выбора модели и усилия здесь больше нет. Он был, и замер его закрыл: 210 прогонов
/// по 17 проверкам на десяти живых записях дали одного победителя без спорных мест, а
/// «экономный» вариант оказался и медленнее, и хуже. Настройка, у которой один правильный
/// ответ, — это приглашение ошибиться, и её место в коде, а не в окне.
private struct AIPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var codex: CodexAuthModel

    @State private var apiKey = ""
    @State private var apiKeyNote: String?
    /// Что лежало в связке, когда окно открылось. Нужен ровно для одного: автосохранение
    /// обязано молчать, пока значение не менялось. Иначе неудачное чтение (поле пустое,
    /// а ключ в связке есть) при закрытии окна стёрло бы живой ключ.
    @State private var storedAPIKey = ""
    // Полное имя обязательно: в CribeCore живёт свой `FocusState` — про поле ввода в чужом
    // приложении, — и короткое имя здесь неоднозначно.
    @SwiftUI.FocusState private var apiKeyFocused: Bool

    var body: some View {
        Form {
            Section {
                Picker("Доступ:", selection: $settings.gptMode) {
                    Text("Аккаунт ChatGPT").tag(GPTAuthMode.codex)
                    Text("API-ключ OpenAI").tag(GPTAuthMode.apiKey)
                }
                .onChange(of: settings.gptMode) { _, _ in
                    // Уход в режим API-ключа прячет блок входа — поллинг за ним не оставляем.
                    codex.cancel()
                }

                switch settings.gptMode {
                case .apiKey: apiKeySection
                case .codex: codexSection
                }
            } header: {
                Text("Доступ")
            } footer: {
                caption(
                    "Ключ и вход в ChatGPT хранятся в связке ключей macOS — в современной её "
                        + "части, где доступ даёт подпись разработчика, а не отдельная сборка. "
                        + "Поэтому пароль от связки приложение не спрашивает, даже после обновления."
                )
            }

            Section {
                Toggle("AI-чистка (GPT)", isOn: $settings.gptEnabled)

                Picker("Переводить на:", selection: $settings.translationTarget) {
                    ForEach(TranslationTarget.allCases, id: \.self) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                .disabled(!settings.gptEnabled)
            } header: {
                Text("Чистка текста")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    caption(
                        "GPT расставляет знаки, убирает слова-паразиты, держит термины словаря "
                            + "и возвращает латиницу английским названиям — распознавание пишет "
                            + "их кириллицей. Поэтому через чистку идёт каждая диктовка, даже "
                            + "однословная."
                    )
                    caption(
                        "Перевод правым ⌥ делает она же: выключенная чистка — это и выключенный "
                            + "перевод. Постоянный перевод включается в меню строки состояния."
                    )
                    if settings.translationTarget.matches(settings.language) {
                        caption(
                            "Язык перевода сейчас совпадает с языком диктовки — переводить "
                                + "нечего, и правый ⌥ работает как обычная диктовка."
                        )
                    }
                    caption("Модель — \(GPTConfig.defaultModel): выбрана замером, менять её не нужно.")
                }
            }
        }
        .settingsForm()
        .task {
            apiKey = SecretStore.getString(SecretStore.apiKeyAccount) ?? ""
            storedAPIKey = apiKey
            await codex.refreshStatus()
        }
        // Окно закрыли, не выходя из поля: фокус так и не сменился, и без этого ключ
        // пропал бы вместе с окном.
        .onDisappear { autosaveAPIKey() }
    }

    // MARK: API-ключ

    @ViewBuilder
    private var apiKeySection: some View {
        // Ключ сохраняется сам: по Enter, по уходу фокуса и при закрытии окна. Раньше
        // сохранение висело только на кнопке — человек вводил ключ, закрывал настройки,
        // и ключ не попадал в связку вовсе. Снаружи это выглядело как «при каждом
        // перезапуске снова просят ключ», хотя терялся он в тот же миг, а не при перезапуске.
        SecureField("API-ключ:", text: $apiKey)
            .focused($apiKeyFocused)
            .onSubmit { saveAPIKey() }
            .onChange(of: apiKeyFocused) { _, focused in
                if !focused { autosaveAPIKey() }
            }
        HStack {
            Button("Сохранить ключ") { saveAPIKey() }
            if let apiKeyNote {
                Text(apiKeyNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Ключ живёт только в связке ключей: ни UserDefaults, ни файлов.
    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SecretStore.delete(SecretStore.apiKeyAccount)
            apiKeyNote = "Ключ удалён"
        } else {
            SecretStore.setString(trimmed, account: SecretStore.apiKeyAccount)
            apiKeyNote = "Ключ сохранён"
        }
        storedAPIKey = trimmed
    }

    /// Сохранение без нажатия кнопки. Молчит, когда значение не менялось, — в том числе
    /// когда поле пустое потому, что прочитать связку не удалось.
    private func autosaveAPIKey() {
        guard APIKeyField.changed(typed: apiKey, stored: storedAPIKey) else { return }
        saveAPIKey()
    }

    /// Вход по коду устройства в ChatGPT выключен по умолчанию: страница принимает код
    /// и молча ничего не делает. Со стороны это неотличимо от сломанного приложения,
    /// поэтому говорим об этом до ввода кода, а не после.
    private var deviceCodeNote: some View {
        Text(
            "Сначала включите в ChatGPT: аватар → Settings → Security → «Enable device "
                + "code authorization». По умолчанию выключено; в рабочем аккаунте включает "
                + "администратор."
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
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
                deviceCodeNote
                Text("Код подтверждения:").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(session.userCode)
                        .font(.title.monospaced())
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
            deviceCodeNote
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

// MARK: - Словарь

private struct DictionaryPane: View {
    let url: URL
    @ObservedObject var settings: AppSettings

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Учиться на моих правках", isOn: $settings.learnsFromEdits)
            } header: {
                Text("Автопополнение")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    caption(
                        "После вставки Cribe пятнадцать секунд смотрит, что вы делаете с текстом. "
                            + "Заметив исправление, спрашивает — добавить ли пару в словарь. "
                            + "Сам он не добавляет ничего."
                    )
                    caption(
                        "Разбирается в увиденном GPT, поэтому наружу уходит содержимое поля "
                            + "за эти пятнадцать секунд — включая то, что вы написали после "
                            + "нашего текста. Не нужно — выключите здесь."
                    )
                }
            }

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
        .settingsForm()
    }
}

// MARK: - О программе

private struct AboutPane: View {
    private static let repository = URL(string: "https://github.com/pnazarovich/cribe")!

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
        (
            "Sparkle",
            "обновление приложения",
            URL(string: "https://github.com/sparkle-project/Sparkle")!
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
                        Text("Cribe").font(.title2)
                        Text("Версия \(Self.version)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Link("github.com/pnazarovich/cribe", destination: Self.repository)
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
                caption("Сам Cribe — под лицензией MIT.")
            }
        }
        .settingsForm()
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

extension View {
    /// Оформление панели раздела — одно на все четыре.
    ///
    /// Свой фон у формы гасим: он рисуется непрозрачным и закрыл бы подложку окна. А вот
    /// плашки секций система рисует полупрозрачной заливкой поверх фона — проверено на
    /// цветной подложке, — и над прозрачным окном они и оказываются стеклом: блюр даёт
    /// подложка окна, плотность — сама плашка. Третьего слоя блюра здесь нет.
    ///
    /// Радиусы, отступы, кант и высоты строк считает `Form`, поэтому они одинаковы во всех
    /// разделах по построению, а не по недосмотру.
    fileprivate func settingsForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

/// Пояснение под секцией: один стиль на все разделы.
private func caption(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
