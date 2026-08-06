import AppKit
import Combine
import KeyboardShortcuts
import OSLog
import SwiftUI
import CribeCore

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", initial: .init(.backtick, modifiers: [.option]))
    static let switchLanguage = Self("switchLanguage", initial: .init(.backtick, modifiers: [.option, .shift]))
    /// Диктовка с переводом. Без значения по умолчанию: в режиме правого ⌘ эту диктовку
    /// запускает правый ⌥, а свой шорткат назначает тот, кому он нужен.
    static let toggleTranslateDictation = Self("toggleTranslateDictation")
}

/// Идентификаторы окон-сцен для `openWindow(id:)`.
enum WindowID {
    static let dictionary = "dictionary"
    static let onboarding = "onboarding"
    static let history = "history"
}

/// Долгоживущие объекты приложения: движок, словарь, конвейер, живая панель.
/// Создаются один раз и живут до выхода — пересоздание сбросило бы прогретые модели.
@MainActor
final class AppCore: ObservableObject {
    static let shared = AppCore()

    let settings = AppSettings.shared
    let history = HistoryStore.shared
    let suggester = TermSuggester.shared
    let engine = WhisperEngine()
    let dictionary = UserDictionary(url: UserDictionary.defaultURL)
    let controller: DictationController

    /// Онбординг показываем один раз; флаг ставим сразу при открытии, иначе окно,
    /// закрытое крестиком, возвращалось бы на каждом старте.
    @Published private(set) var needsOnboarding: Bool

    /// Зачем открыли редактор словаря из меню. Редактор разворачивает нужный блок
    /// и сбрасывает значение — это разовый сигнал, а не состояние.
    @Published var dictionaryFocus: DictionaryFocus?

    private static let onboardingKey = "onboardingShown"

    private var panel: LivePanel?
    private var notices: NoticePanel?
    private var cards: CardStackController?
    private var rightCommandTap: ModifierKeyTap?
    private var rightOptionTap: ModifierKeyTap?
    private var escTap: KeyDownTap?
    private var hotkeyModeSubscription: AnyCancellable?
    private var escTapSubscription: AnyCancellable?
    /// Об отсутствии разрешения пишем один раз на серию попыток, а не на каждую активацию.
    private var loggedEscFailure = false
    /// Состояние хоткей-тапов, уже записанное в журнал. Строку пишем только на его смену:
    /// `retryHotkeyTapIfNeeded` зовётся на каждой активации приложения.
    private var loggedTapState: Bool?
    private let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Hotkey")

    private init() {
        controller = DictationController(engine: engine, dictionary: dictionary, settings: settings)
        needsOnboarding = !UserDefaults.standard.bool(forKey: Self.onboardingKey)
        // Чаймы синтезируются заранее: на первом хоткее звук иначе опаздывал.
        SoundPlayer.preload()
        suggester.refresh(entries: dictionary.entries)
        // Словарь меняется и мимо редактора (правка файла снаружи) — подсказки обязаны
        // это учесть, иначе они предлагают то, что уже добавлено. Уведомление приходит
        // с очереди наблюдателя, а `@Published` живёт на главной.
        dictionary.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.suggester.refresh(entries: self.dictionary.entries)
            }
        }
    }

    /// Панель и глобальные хоткеи поднимаются после старта NSApplication.
    func start() {
        guard panel == nil else { return }
        // Расписание проверок обновлений заводится здесь же: до старта NSApplication
        // показывать найденное обновление было бы нечем.
        UpdateController.shared.start()
        panel = LivePanel(controller: controller, settings: settings)
        // Записка рядом с панелью: пилюля показывает одно дело, а с наложением их бывает
        // два сразу. Всё, что в неё не влезло, ядро отдаёт сюда поводом, а слова к поводу
        // подбирает `NoticeText`.
        let notices = NoticePanel()
        self.notices = notices
        controller.onNotice = { [settings] notice in
            notices.show(NoticeText.line(for: notice, hotkey: settings.dictationHotkeyMode))
        }
        // Ядро остаётся без UI: оно только сообщает, что вставлять было некуда, а карточку
        // из этого делает уже приложение. Перевод карточки — тоже дело приложения: только
        // здесь есть и настройки GPT, и словарь.
        let cards = CardStackController(
            translator: CardTranslator(
                isAvailable: { [settings] in settings.gptEnabled },
                translate: { [settings, dictionary] text in
                    try await PostProcessor.cleanup(
                        text: text,
                        entries: dictionary.entries,
                        language: settings.language,
                        config: settings.translateGPTConfig,
                        translateToEnglish: true
                    )
                }
            )
        )
        self.cards = cards
        // Текст уехал в карточку — значит, капсула не «вставила», а донесла: она улетает
        // вниз-влево и там становится карточкой. Порядок важен: сначала запускаем перелёт
        // (он стартует ровно в кадре капсулы), и только потом убираем саму капсулу.
        controller.onCardText = { [weak self] text in
            guard let self, let cards = self.cards else { return false }
            // Пилюлю могла занять СЛЕДУЮЩАЯ запись: при наложении текст доезжает, пока
            // человек уже говорит дальше. Тогда лететь из пилюли нельзя — это было бы
            // враньём, а `handOffToCard` вдобавок сдёрнул бы её с экрана посреди живой
            // диктовки. Карточка в таком случае приезжает обычным выездом слева.
            var source = panel?.pillFrame
            if case .recording = self.controller.state { source = nil }
            guard cards.push(text, flyingFrom: source) else { return false }
            // Капсула замолкает, только если эстафету и правда приняла летящая фигура:
            // перелёт САМ показывает, куда уехал текст, и вспышка «⤷ В карточку» следом —
            // второй раз про то же самое. При «Уменьшить движение» перелёта нет, и эта
            // вспышка остаётся единственным ответом — тогда капсула договаривает.
            if source != nil, CardFlight.flies { panel?.handOffToCard() }
            return true
        }
        // Шорткат живёт в обоих режимах: параллельный путь к той же диктовке никому не мешает.
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [controller] in controller.toggle() }
        KeyboardShortcuts.onKeyUp(for: .switchLanguage) { [controller] in controller.switchLanguage() }
        KeyboardShortcuts.onKeyUp(for: .toggleTranslateDictation) { [controller] in
            controller.toggle(translating: true)
        }

        // Каждый тап знает device-бит соседа: аккорд «⌘ удержан + тап ⌥» (и наоборот)
        // диктовку не запускает — это две хоткей-клавиши друг с другом, а не тап.
        rightCommandTap = ModifierKeyTap(
            blockingFlags: ModifierTapDetector.rightOptionFlag
        ) { [controller] in controller.toggle() }
        // Правый ⌥ — та же диктовка, но переводящая: решение принимается на старте сессии,
        // а остановить запись вправе любая из двух клавиш.
        rightOptionTap = ModifierKeyTap(
            keyCode: ModifierTapDetector.rightOptionKeyCode,
            deviceFlag: ModifierTapDetector.rightOptionFlag,
            blockingFlags: ModifierTapDetector.rightCommandFlag
        ) { [controller] in controller.toggle(translating: true) }
        // `@Published` отдаёт текущее значение при подписке — режим применится и на старте.
        hotkeyModeSubscription = settings.$dictationHotkeyMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mode in
                MainActor.assumeIsolated { self?.applyHotkeyMode(mode) }
            }

        // Esc отменяет диктовку — это выход из идущей сессии, а не второй способ её запустить,
        // поэтому от режима хоткеев он не зависит и живёт в обоих.
        escTap = KeyDownTap(keyCode: KeyDownTap.escapeKeyCode) { [controller] in
            controller.cancelDictation()
        }
        // Тап поднимаем только на живой сессии: слушать всю клавиатуру, когда отменять нечего,
        // незачем. Поток уровня записи (~12 обновлений в секунду) до тапа не доходит —
        // состояние свёрнуто в один флаг.
        escTapSubscription = controller.$state
            .map(Self.sessionIsLive)
            .removeDuplicates()
            .sink { [weak self] live in
                // `state` мутируется только на MainActor (DictationController — @MainActor).
                MainActor.assumeIsolated { self?.applyEscTap(live: live) }
            }
    }

    /// Запись, которую есть что отменять. Обработка сюда НЕ входит: Esc отменяет только то,
    /// что пишется прямо сейчас, а уже записанные диктовки он не трогает (см.
    /// `DictationController.cancelDictation`). Терминальные состояния — тем более.
    private static func sessionIsLive(_ state: DictationState) -> Bool {
        switch state {
        case .preparingModel, .recording: return true
        case .transcribing, .cleaning, .idle, .inserted, .carded, .cancelled, .degraded, .error:
            return false
        }
    }

    private func applyEscTap(live: Bool) {
        guard let escTap else { return }
        guard live else {
            escTap.stop()
            return
        }
        // Разрешение то же, что у остальных тапов и у вставки, — пишем о его отсутствии
        // один раз на серию сессий, а не на каждую.
        if escTap.start() {
            loggedEscFailure = false
        } else if !loggedEscFailure {
            loggedEscFailure = true
            logger.error("Esc не отменяет диктовку: нет разрешения Accessibility")
        }
    }

    /// Повторная попытка после выдачи Accessibility: разрешение дают в System Settings уже
    /// после старта, а `start()` идемпотентна — на работающем тапе вызов ничего не делает.
    func retryHotkeyTapIfNeeded() {
        applyHotkeyMode(settings.dictationHotkeyMode)
    }

    private func applyHotkeyMode(_ mode: HotkeyMode) {
        guard let rightCommandTap, let rightOptionTap else { return }
        switch mode {
        case .rightCommand:
            // Оба тапа поднимаем всегда: `&&` пропустил бы второй вызов, а состояния тапов
            // должны совпадать. Разрешение у них общее — падают и поднимаются они вместе.
            let commandStarted = rightCommandTap.start()
            let optionStarted = rightOptionTap.start()
            logTapState(started: commandStarted && optionStarted)
        case .custom:
            rightCommandTap.stop()
            rightOptionTap.stop()
            loggedTapState = nil
        }
    }

    /// Единственная запись о хоткее в журнале: без неё «правый ⌘ не работает» неотличимо от
    /// «тап не поднялся», а причина почти всегда одна — не выдан Accessibility.
    /// Смотреть так: `log show --predicate 'subsystem == "online.nazarovych.cribe"' --last 1h`
    private func logTapState(started: Bool) {
        guard loggedTapState != started else { return }
        loggedTapState = started
        let state = started
            ? "подключены"
            : (TextInserter.hasAccessibility
                ? "не подключены: Accessibility выдан, но тап не создался"
                : "не подключены: нет разрешения Accessibility")
        logger.notice("Правые ⌘/⌥ \(state, privacy: .public)")
    }

    func markOnboardingShown() {
        needsOnboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }
}

/// Единственная задача делегата — точка «приложение стартовало».
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppCore.shared.start() }
    }

    /// Возврат в приложение — обычный момент после выдачи Accessibility в System Settings.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppCore.shared.retryHotkeyTapIfNeeded() }
    }
}

@main
struct CribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Продукт переименовали, а данные владельца остались под старым именем. Переезд —
        // самым первым делом: `body` ниже трогает `AppCore.shared`, а тот на своём создании
        // читает настройки и путь к моделям, и читать они должны уже переехавшее.
        LegacyRename.run()
    }

    var body: some Scene {
        MenuBarScene(core: AppCore.shared, controller: AppCore.shared.controller)

        Settings {
            SettingsView(settings: AppCore.shared.settings, dictionaryURL: UserDictionary.defaultURL)
        }

        Window("Словарь", id: WindowID.dictionary) {
            DictionaryWindow(
                core: AppCore.shared,
                controller: AppCore.shared.controller,
                history: AppCore.shared.history
            )
        }
        .defaultSize(width: 680, height: 560)

        // История — единственная дверь к сохранённым записям: только отсюда диктовку,
        // из которой распознавание потеряло речь, можно разобрать заново.
        Window("История диктовок", id: WindowID.history) {
            HistoryView(
                history: AppCore.shared.history,
                controller: AppCore.shared.controller,
                settings: AppCore.shared.settings
            )
        }
        .defaultSize(width: 680, height: 560)

        Window("Настройка Cribe", id: WindowID.onboarding) {
            OnboardingView(
                engine: AppCore.shared.engine,
                settings: AppCore.shared.settings,
                // Флаг первого запуска гасим отсюда: только появление окна доказывает,
                // что онбординг пользователь действительно увидел.
                onShown: { AppCore.shared.markOnboardingShown() },
                // Accessibility выдают в System Settings, не выходя из онбординга: тапы
                // правых ⌘/⌥ обязаны подняться сразу, а не после возврата в приложение.
                onAccessibilityGranted: { AppCore.shared.retryHotkeyTapIfNeeded() }
            )
        }
        .windowResizability(.contentSize)
    }
}

/// Единственное место, где редактор словаря встречается с общим состоянием приложения:
/// сам он про `AppCore` не знает и живёт на переданных ему словаре, настройках и тексте
/// последней диктовки.
private struct DictionaryWindow: View {
    @ObservedObject var core: AppCore
    @ObservedObject var controller: DictationController
    @ObservedObject var history: HistoryStore

    var body: some View {
        DictionaryEditorView(
            dictionary: core.dictionary,
            settings: core.settings,
            suggester: core.suggester,
            // Последняя диктовка живёт в конвейере, но после перезапуска её там нет —
            // тогда берём свежайшую из истории.
            lastDictation: controller.lastOriginal ?? history.items.first?.text,
            focus: $core.dictionaryFocus
        )
    }
}

/// Меню-бар вынесен в отдельную сцену ради `openWindow`: это значение окружения
/// доступно во вью и сценах, но не в теле `App`. Отсюда же открывается онбординг.
private struct MenuBarScene: Scene {
    @ObservedObject var core: AppCore
    @ObservedObject var controller: DictationController

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                core: core,
                controller: controller,
                settings: core.settings,
                history: core.history,
                suggester: core.suggester,
                updates: UpdateController.shared
            )
        } label: {
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: core.needsOnboarding, initial: true) { _, needs in
            guard needs else { return }
            // Следующим тиком: сцены окон к этому моменту зарегистрированы.
            // Флаг гасит сам онбординг при появлении — если окно почему-то не открылось,
            // попытка повторится на следующем запуске, а вручную его зовёт пункт меню.
            Task { @MainActor in
                WindowPresenter.shared.present(WindowID.onboarding) {
                    openWindow(id: WindowID.onboarding)
                }
            }
        }
    }

    private var icon: String {
        if case .recording = controller.state { return "waveform.badge.mic" }
        return "waveform"
    }
}
