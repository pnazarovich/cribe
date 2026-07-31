import AppKit
import Combine
import SwiftUI
import TranscriberCore

/// Плавающая панель прогресса: сама подписана на состояние конвейера,
/// появляется на любом состоянии кроме `.idle` и уходит на `.idle`.
/// Ключевой инвариант — панель никогда не становится key/main, иначе Cmd-V уйдёт не в то окно.
@MainActor
public final class LivePanel {

    /// Окно с запасом вокруг пилюли (190×44, до 320 на длинной ошибке): она висит по центру,
    /// остальное прозрачно. Запас нужен, чтобы широкая ошибка не обрезалась по краям.
    private static let width: CGFloat = 360
    private static let height: CGFloat = 80
    /// Отступ окна от нижнего края экрана.
    private static let bottomInset: CGFloat = 80
    /// Небольшая задержка на скрытии, чтобы «✓ Вставлено» не мигало.
    private static let hideDelay: Duration = .milliseconds(300)

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
            case .transcribing, .cleaning, .inserted, .degraded, .error: self = .processing
            }
        }
    }

    private let panel: NSPanel
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень рисовалась бы по прямоугольнику окна, а не по капсуле.
        panel.hasShadow = false
        // Панель чисто информационная: клики должны доходить до окна под ней.
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: PanelView(controller: controller, settings: settings))

        // Окно трогаем только на смене фазы: поток уровня (~12 обновлений в секунду)
        // целиком укладывается в одну фазу и до окна не доходит.
        cancellable = controller.$state
            .map(Phase.init)
            .removeDuplicates()
            .sink { [weak self] phase in
                // `state` мутируется только на MainActor (DictationController — @MainActor).
                MainActor.assumeIsolated { self?.apply(phase) }
            }
    }

    public func show() {
        hideTask?.cancel()
        hideTask = nil
        moveToCursorScreen()
        panel.orderFrontRegardless()  // именно так: makeKey увёл бы фокус с целевого поля
    }

    public func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
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
            guard !Task.isCancelled else { return }
            self?.hide()
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
