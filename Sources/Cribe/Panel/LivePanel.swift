import AppKit
import Combine
import OSLog
import SwiftUI
import CribeCore

/// Что панель показывает прямо сейчас. Видимостью управляет `LivePanel`, а не состояние
/// конвейера напрямую: на `.idle` капсула ещё доигрывает уход, и кадр ей нужен последний
/// непустой — иначе она гасла бы пустой.
@MainActor
final class PanelPresentation: ObservableObject {
    @Published var isVisible = false
    @Published var state: DictationState = .idle
}

/// Плавающая панель прогресса: сама подписана на состояние конвейера,
/// появляется на любом состоянии кроме `.idle` и уходит на `.idle`.
/// Ключевой инвариант — панель никогда не становится key/main, иначе Cmd-V уйдёт не в то окно.
@MainActor
public final class LivePanel {

    /// Окно с запасом вокруг пилюли (190×44, до 320 на длинной ошибке): она висит по центру,
    /// остальное прозрачно. Запас нужен, чтобы широкая ошибка не обрезалась по краям,
    /// а мягкая тень (радиус 12 со сдвигом вниз) уместилась целиком — отсюда ~24 pt на сторону.
    private static let width: CGFloat = 380
    private static let height: CGFloat = 92
    /// Отступ окна от нижнего края экрана.
    private static let bottomInset: CGFloat = 80
    /// Небольшая задержка на скрытии, чтобы «✓ Вставлено» не мигало.
    private static let hideDelay: Duration = .milliseconds(300)
    /// Окно живёт, пока капсула доигрывает уход: убрать его раньше — обрезать анимацию.
    /// Чуть больше самой анимации (0.3), с запасом на кадр.
    private static let exitDuration: Duration = .milliseconds(350)

    /// Появление — пружина с лёгким перелётом: капсула всплывает снизу и «садится» на место.
    /// Уход — без пружины: короткое гладкое оседание. При «Уменьшить движение» и то, и другое
    /// вырождается в обычное перекрёстное затухание.
    /// Отклик пружины появления. Было 0.35 — и именно он, а не конвейер, делал капсулу
    /// «неторопливой»: замер пути от хоткея до показа дал 70 мс на первой диктовке и 19 мс
    /// на второй, то есть ждать было нечего, а глаз всё равно видел, как она выплывает.
    /// Затухание поднято вместе с откликом: на быстрой пружине прежние 0.72 читались бы
    /// уже не как жизнь, а как дрожь.
    private static var appearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.18, dampingFraction: 0.8)
    }

    private static var disappearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }

    /// Всё, что панели нужно знать о состоянии конвейера. `.starting` наступает ровно один раз
    /// за сессию: вернуться в `.preparingModel`/`.recording` можно только новой сессией —
    /// во время распознавания и чистки хоткей игнорируется, а из `.inserted`/`.degraded`/`.error`
    /// конвейер уходит туда только через `begin()`. Поэтому смена фазы на `.starting` —
    /// надёжный признак новой сессии, даже если `.idle` между ними не было.
    /// Не private: раскладку «эстафета отдана + фаза → возвращаться ли капсуле» проверяет тест,
    /// а живая панель тянет за собой весь конвейер.
    enum Phase {
        case hidden
        case starting
        case processing

        init(_ state: DictationState) {
            switch state {
            // Удачная вставка — это НЕ повод показывать что-то ещё: текст уже стоит в поле,
            // человек его видит, и вспышка «Вставлено» поверх собственного текста только
            // мешает. Капсула уходит ровно в тот момент, когда текст доехал.
            case .idle, .inserted: self = .hidden
            case .preparingModel, .recording: self = .starting
            // `.cancelled` — тоже видимая фаза: вспышку «Отменено» надо успеть показать,
            // а панель прячет только `.idle` следом за ней. `.carded` и `.degraded` тем
            // более: там текст уехал не в поле либо уехал с оговоркой.
            case .transcribing, .cleaning, .carded, .cancelled, .degraded, .error:
                self = .processing
            }
        }
    }

    /// Не `let`: оболочка окна меняется на каждом показе (см. `HUDWindow.renew`).
    private var panel: NSPanel
    private let presentation = PanelPresentation()
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var phase: Phase = .hidden
    /// Эстафета отдана карточке: капсула улетела и до конца сессии молчит.
    private var handedOffToCard = false

    public init(controller: DictationController, settings: AppSettings) {
        panel = Self.makeShell()
        panel.contentView = NSHostingView(
            rootView: PanelView(presentation: presentation, controller: controller, settings: settings)
        )

        cancellable = controller.$state
            .sink { [weak self] state in
                // `state` мутируется только на MainActor (DictationController — @MainActor).
                MainActor.assumeIsolated { self?.handle(state) }
            }
    }

    public func show() {
        hideTask?.cancel()
        hideTask = nil
        // Оболочку окна берём свежую: у прожившей часами прописка во всех пространствах
        // протухает, и пилюля перестаёт появляться вовсе (см. `HUDWindow`). Видимое окно
        // не трогаем — это показ поверх ещё не доигравшего ухода, и капсула обязана
        // вернуться тем же движением назад, а не мигнуть новым окном.
        if !panel.isVisible { panel = HUDWindow.renew(panel) { Self.makeShell() } }
        moveToCursorScreen()
        HUDWindow.orderFront(panel, extra: .stationary)
        // Анимируем содержимое, а не окно: окно просто есть, капсула в нём всплывает.
        withAnimation(Self.appearAnimation) { presentation.isVisible = true }
    }

    /// Кадр капсулы на экране — точка старта перелёта в карточку. `nil`, если капсулы
    /// сейчас нет: лететь тогда неоткуда, карточка появится обычным выездом слева.
    ///
    /// Капсула висит по центру окна панели и в рабочих состояниях держит один габарит
    /// (190×44) — шире она становится только на длинной ошибке, а туда путь в карточку
    /// не ведёт.
    public var pillFrame: CGRect? {
        guard panel.isVisible, presentation.isVisible else { return nil }
        let frame = panel.frame
        return CGRect(
            x: (frame.midX - PanelPill.width / 2).rounded(),
            y: (frame.midY - PanelPill.height / 2).rounded(),
            width: PanelPill.width,
            height: PanelPill.height
        )
    }

    /// Капсула передала эстафету летящей фигуре: убираем её мгновенно и без анимации —
    /// иначе на экране одновременно и «улетело», и «растаяло на месте».
    public func handOffToCard() {
        hideTask?.cancel()
        hideTask = nil
        handedOffToCard = true
        presentation.isVisible = false
        panel.orderOut(nil)
        // Фаза возвращается в «скрыто» руками: следующая сессия обязана снова показать
        // капсулу, а `handle` реагирует только на СМЕНУ фазы.
        phase = .hidden
    }

    /// Немедленное скрытие без анимации — на случай принудительного вызова извне.
    public func hide() {
        hideTask?.cancel()
        hideTask = nil
        presentation.isVisible = false
        panel.orderOut(nil)
    }

    /// Возвращается ли капсула на экран после того, как эстафету приняла карточка.
    ///
    /// Чистая функция — её и проверяет тест. Правило одно: пока сессия не началась заново,
    /// улетевшая капсула не показывается НИ НА ЧЁМ. Иначе следом за перелётом вспыхивало
    /// «⤷ В карточку» — второй раз про то же самое, да ещё и посреди экрана, где карточки
    /// уже нет: на глаз это читается как мигание.
    static func wakesUp(handedOffToCard: Bool, next phase: Phase) -> Bool {
        guard handedOffToCard else { return true }
        return phase == .starting
    }

    private func handle(_ state: DictationState) {
        // Последний непустой кадр остаётся на экране, пока капсула уходит: и на `.idle`,
        // и на удачной вставке. Во втором случае это «✨ Чищу…» — то, чем капсула и была
        // занята; менять её содержимое на прощание значит показать новый кадр ради того,
        // чтобы тут же его стереть.
        switch state {
        case .idle, .inserted: break
        default: presentation.state = state
        }
        // Окно трогаем только на смене фазы: поток уровня (~12 обновлений в секунду)
        // целиком укладывается в одну фазу и до окна не доходит.
        let next = Phase(state)
        guard Self.wakesUp(handedOffToCard: handedOffToCard, next: next) else { return }
        // Новая сессия — эстафета снова у капсулы.
        handedOffToCard = false
        guard next != phase else { return }
        apply(next)
    }

    private func apply(_ next: Phase) {
        defer { phase = next }
        switch next {
        case .starting:
            // Начало сессии — единственный момент, когда позицию надо пересчитать:
            // курсор мог переехать на другой экран, пока висел хвост прошлой сессии.
            show()
        case .processing:
            // Сессия может упасть в .error, минуя .starting (сбой ещё до записи).
            if phase == .hidden { show() }
        case .hidden:
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Self.disappearAnimation) { self.presentation.isVisible = false }
            try? await Task.sleep(for: Self.exitDuration)
            guard !Task.isCancelled else { return }
            // Окно убираем, только когда капсула уже растаяла. Показ, случившийся до этого
            // момента, отменяет задачу — и капсула возвращается тем же движением назад,
            // без мигания окна.
            panel.orderOut(nil)
            hideTask = nil
        }
    }

    /// Оболочка окна пилюли — без содержимого: его строит `init` один раз и дальше оно
    /// переезжает из оболочки в оболочку.
    private static func makeShell() -> NSPanel {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Ярус и поведение — общий рецепт HUD (см. `HUDWindow`): панель обязана появляться
        // поверх чужого полноэкранного пространства. `.stationary` — чтобы пилюля
        // не разъезжалась вместе с окнами на Mission Control.
        panel.level = HUDWindow.level
        panel.collectionBehavior = HUDWindow.spaceBehavior.union(.stationary)
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень рисовалась бы по прямоугольнику окна, а не по капсуле: тени рисует SwiftUI.
        panel.hasShadow = false
        panel.animationBehavior = .utilityWindow
        // Панель чисто информационная: клики должны доходить до окна под ней.
        panel.ignoresMouseEvents = true
        return panel
    }

    /// Низ по центру экрана, на котором сейчас курсор (там же, где и целевое окно).
    private func moveToCursorScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: (screen.frame.midX - Self.width / 2).rounded(),
                y: (screen.frame.minY + Self.bottomInset).rounded()
            )
        )
    }
}

/// `canBecomeKey` / `canBecomeMain` у NSWindow только для чтения — отключаются переопределением.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
