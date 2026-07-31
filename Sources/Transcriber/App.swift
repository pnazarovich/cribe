import AppKit
import KeyboardShortcuts
import SwiftUI
import TranscriberCore

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", initial: .init(.backtick, modifiers: [.option]))
    static let switchLanguage = Self("switchLanguage", initial: .init(.backtick, modifiers: [.option, .shift]))
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

    private init() {
        controller = DictationController(engine: engine, dictionary: dictionary, settings: settings)
        needsOnboarding = !UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }

    /// Панель и глобальные хоткеи поднимаются после старта NSApplication.
    func start() {
        guard panel == nil else { return }
        panel = LivePanel(controller: controller, settings: settings)
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [controller] in controller.toggle() }
        KeyboardShortcuts.onKeyUp(for: .switchLanguage) { [controller] in controller.switchLanguage() }
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
            OnboardingView(engine: AppCore.shared.engine)
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
            // Следующим тиком: сцены окон к этому моменту зарегистрированы, а мутация
            // состояния не приходится на текущий проход обновления.
            Task { @MainActor in
                core.markOnboardingShown()
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
