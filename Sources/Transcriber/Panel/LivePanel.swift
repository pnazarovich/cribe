import AppKit
import Combine
import SwiftUI
import TranscriberCore

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
    private static var appearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.35, dampingFraction: 0.72)
    }

    private static var disappearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }

    /// Всё, что панели нужно знать о состоянии конвейера. `.starting` наступает ровно один раз
    /// за сессию: вернуться в `.preparingModel`/`.recording` можно только новой сессией —
    /// во время распознавания и чистки хоткей игнорируется, а из `.inserted`/`.degraded`/`.error`
    /// конвейер уходит туда только через `begin()`. Поэтому смена фазы на `.starting` —
    /// надёжный признак новой сессии, даже если `.idle` между ними не было.
    private enum Phase {
        case hidden
        case starting
        case processing

        init(_ state: DictationState) {
            switch state {
            case .idle: self = .hidden
            case .preparingModel, .recording: self = .starting
            // `.cancelled` — тоже видимая фаза: вспышку «Отменено» надо успеть показать,
            // а панель прячет только `.idle` следом за ней.
            case .transcribing, .cleaning, .inserted, .carded, .cancelled, .degraded, .error:
                self = .processing
            }
        }
    }

    private let panel: NSPanel
    private let presentation = PanelPresentation()
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var phase: Phase = .hidden

    public init(controller: DictationController, settings: AppSettings) {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Ярус HUD: панель диктовки должна лежать поверх обычных плавающих окон.
        panel.level = .statusBar
        // `.stationary` — чтобы пилюля не разъезжалась вместе с окнами на Mission Control.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень рисовалась бы по прямоугольнику окна, а не по капсуле: тени рисует SwiftUI.
        panel.hasShadow = false
        panel.animationBehavior = .utilityWindow
        // Панель чисто информационная: клики должны доходить до окна под ней.
        panel.ignoresMouseEvents = true
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
        moveToCursorScreen()
        panel.orderFrontRegardless()  // именно так: makeKey увёл бы фокус с целевого поля
        // Анимируем содержимое, а не окно: окно просто есть, капсула в нём всплывает.
        withAnimation(Self.appearAnimation) { presentation.isVisible = true }
    }

    /// Немедленное скрытие без анимации — на случай принудительного вызова извне.
    public func hide() {
        hideTask?.cancel()
        hideTask = nil
        presentation.isVisible = false
        panel.orderOut(nil)
    }

    private func handle(_ state: DictationState) {
        // Последний непустой кадр остаётся на экране, пока капсула уходит.
        if case .idle = state {} else { presentation.state = state }
        // Окно трогаем только на смене фазы: поток уровня (~12 обновлений в секунду)
        // целиком укладывается в одну фазу и до окна не доходит.
        let next = Phase(state)
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
