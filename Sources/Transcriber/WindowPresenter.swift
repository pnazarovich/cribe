import AppKit

/// Обычные окна приложения — настройки, редактор словаря, онбординг — открываются из меню
/// в строке состояния, а LSUIElement-приложение в этот момент неактивно. Само по себе окно
/// сцены при этом рождается ПОЗАДИ чужих: `SettingsLink` не активирует приложение вовсе,
/// а одного `NSApp.activate()` мало — окно создаётся уже после активации, и наведение
/// порядка её не застаёт.
///
/// Отсюда единственное место с рецептом: активировать, открыть, а следующим тиком — когда
/// окно действительно существует — вытащить его вперёд.
///
/// Пока открыто хоть одно такое окно, приложение живёт обычным (`.regular`): иконка в Dock
/// и место в ⌘-Tab — единственный способ вернуться к настройкам, закрытым чужим окном.
/// Закрытие последнего возвращает `.accessory`, и приложение снова только в строке меню.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()

    private var closeObserver: NSObjectProtocol?

    private init() {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Уведомление приходит ДО того, как окно уйдёт с экрана: оставшиеся считаем
            // следующим тиком, иначе закрываемое окно попадёт в счёт само.
            Task { @MainActor in
                guard WindowPresenter.managedWindows().isEmpty else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Сколько ждём появления окна, прежде чем сдаться. Из меню окно готово к первому же
    /// тику, а вот на первом запуске (онбординг) сцены в этот момент ещё только собираются:
    /// под нагрузкой замерено больше секунды до того, как окно вообще заведётся.
    private static let waitAttempts = 60
    private static let waitStep = Duration.milliseconds(50)

    /// Открыть окно (`openWindow`, `openSettings`) и довести его до переднего плана.
    ///
    /// `sceneID` — идентификатор сцены (`WindowID.…`). По нему окно и опознаётся, потому что
    /// на первом запуске SwiftUI заводит окно онбординга НЕВИДИМЫМ и показывает его сам
    /// секунд через десять — уже позади чужих окон (замерено под нагрузкой). Признака
    /// «появилось новое видимое окно» в этот момент нет, ждать его бесполезно: поднимать
    /// надо именно то окно, которое уже существует, но ещё не на экране.
    /// Настройкам идентификатора не досталось — там остаётся поиск по новому окну.
    func present(_ sceneID: String? = nil, _ open: () -> Void) {
        let known = Set(Self.managedWindows().map(ObjectIdentifier.init))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        open()
        Task { @MainActor in
            for _ in 0..<Self.waitAttempts {
                if let window = Self.target(sceneID: sceneID, known: known) {
                    // Активацию повторяем: к моменту рождения окна прежняя заявка могла
                    // и не доехать. `makeKeyAndOrderFront` даёт фокус внутри приложения,
                    // `orderFrontRegardless` — показ поверх чужих окон даже без активации.
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: Self.waitStep)
            }
        }
    }

    /// Окно, которое надо вытащить вперёд.
    ///
    /// С идентификатором сцены — окно с этим именем: SwiftUI кладёт его в
    /// `frameAutosaveName`, оттуда же берётся ключ «NSWindow Frame <id>» в UserDefaults.
    /// Без идентификатора — любое, которого на экране до открытия не было; если сцена лишь
    /// показала уже открытое, ждать нечего: внутри приложения его подняла сама сцена.
    private static func target(sceneID: String?, known: Set<ObjectIdentifier>) -> NSWindow? {
        guard let sceneID else {
            return managedWindows().first { !known.contains(ObjectIdentifier($0)) }
        }
        return managedWindows(visibleOnly: false).first { $0.frameAutosaveName == sceneID }
    }

    /// Окна, которыми презентер управляет, — обычные окна сцен. Пилюля и карточки под это
    /// не попадают: они `NSPanel` и без заголовка, и такими обязаны остаться — сделать их
    /// key значит увести фокус с того самого поля, куда вставляется текст.
    ///
    /// `visibleOnly` держит учёт политики активации честным (закрытое окно в счёт не идёт),
    /// а поиск цели ведётся и по невидимым — ради того самого окна первого запуска.
    private static func managedWindows(visibleOnly: Bool = true) -> [NSWindow] {
        NSApp.windows.filter { window in
            (window.isVisible || !visibleOnly)
                && !(window is NSPanel)
                && window.styleMask.contains(.titled)
        }
    }
}
