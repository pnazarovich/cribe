import AppKit
import Combine
import KeyboardShortcuts
import OSLog
import SwiftUI
import TranscriberCore

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
}

/// Долгоживущие объекты приложения: движок, словарь, конвейер, живая панель.
/// Создаются один раз и живут до выхода — пересоздание сбросило бы прогретые модели.
@MainActor
final class AppCore: ObservableObject {
    static let shared = AppCore()

    let settings = AppSettings.shared
    let history = HistoryStore.shared
    let engine = WhisperEngine()
    let dictionary = UserDictionary(url: UserDictionary.defaultURL)
    let controller: DictationController

    /// Онбординг показываем один раз; флаг ставим сразу при открытии, иначе окно,
    /// закрытое крестиком, возвращалось бы на каждом старте.
    @Published private(set) var needsOnboarding: Bool

    private static let onboardingKey = "onboardingShown"

    private var panel: LivePanel?
    private var cards: CardStackController?
    private var rightCommandTap: ModifierKeyTap?
    private var rightOptionTap: ModifierKeyTap?
    private var escTap: KeyDownTap?
    private var hotkeyModeSubscription: AnyCancellable?
    private var escTapSubscription: AnyCancellable?
    /// Об отсутствии разрешения пишем один раз на серию попыток, а не на каждую активацию.
    private var loggedTapFailure = false
    private var loggedEscFailure = false
    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "Hotkey")

    private init() {
        controller = DictationController(engine: engine, dictionary: dictionary, settings: settings)
        needsOnboarding = !UserDefaults.standard.bool(forKey: Self.onboardingKey)
        // Чаймы синтезируются заранее: на первом хоткее звук иначе опаздывал.
        SoundPlayer.preload()
    }

    /// Панель и глобальные хоткеи поднимаются после старта NSApplication.
    func start() {
        guard panel == nil else { return }
        panel = LivePanel(controller: controller, settings: settings)
        // Ядро остаётся без UI: оно только сообщает, что вставлять было некуда, а карточку
        // из этого делает уже приложение.
        let cards = CardStackController()
        self.cards = cards
        // Текст уехал в карточку — значит, капсула не «вставила», а донесла: она улетает
        // вниз-влево и там становится карточкой. Порядок важен: сначала запускаем перелёт
        // (он стартует ровно в кадре капсулы), и только потом убираем саму капсулу.
        controller.onCardText = { [weak self] text in
            guard let self, let cards = self.cards else { return false }
            let source = panel?.pillFrame
            guard cards.push(text, flyingFrom: source) else { return false }
            if source != nil { panel?.handOffToCard() }
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

    /// Сессия, которую есть что отменять. Терминальные состояния (включая саму вспышку
    /// «Отменено») сюда не входят: там Esc уже ничего не делает.
    private static func sessionIsLive(_ state: DictationState) -> Bool {
        switch state {
        case .preparingModel, .recording, .transcribing, .cleaning: return true
        case .idle, .inserted, .carded, .cancelled, .degraded, .error: return false
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
            // Без Accessibility тап не поднимется — настройки показывают это подсказкой.
            // Пишем поимённо: так видно, отвалилась одна клавиша или обе сразу.
            if commandStarted, optionStarted {
                loggedTapFailure = false
            } else if !loggedTapFailure {
                loggedTapFailure = true
                if !commandStarted {
                    logger.error("Правый ⌘ не подключён: нет разрешения Accessibility")
                }
                if !optionStarted {
                    logger.error("Правый ⌥ не подключён: нет разрешения Accessibility")
                }
            }
        case .custom:
            rightCommandTap.stop()
            rightOptionTap.stop()
        }
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
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarScene(core: AppCore.shared, controller: AppCore.shared.controller)

        Settings {
            SettingsView(settings: AppCore.shared.settings, dictionaryURL: UserDictionary.defaultURL)
        }

        Window("Словарь", id: WindowID.dictionary) {
            DictionaryEditorView(dictionary: AppCore.shared.dictionary)
        }
        .defaultSize(width: 640, height: 420)

        Window("Настройка Transcriber", id: WindowID.onboarding) {
            // Флаг первого запуска гасим отсюда: только появление окна доказывает,
            // что онбординг пользователь действительно увидел.
            OnboardingView(engine: AppCore.shared.engine) { AppCore.shared.markOnboardingShown() }
        }
        .windowResizability(.contentSize)
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
            MenuBarView(controller: controller, settings: core.settings, history: core.history)
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
                // LSUIElement-приложение неактивно — без этого окно откроется позади чужих.
                NSApp.activate()
                openWindow(id: WindowID.onboarding)
            }
        }
    }

    private var icon: String {
        if case .recording = controller.state { return "waveform.badge.mic" }
        return "waveform"
    }
}
