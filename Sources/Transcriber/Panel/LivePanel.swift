import AppKit
import Combine
import SwiftUI
import TranscriberCore

/// Плавающая панель прогресса: сама подписана на состояние конвейера,
/// появляется на любом состоянии кроме `.idle` и уходит на `.idle`.
/// Ключевой инвариант — панель никогда не становится key/main, иначе Cmd-V уйдёт не в то окно.
@MainActor
public final class LivePanel {

    /// Ширина окна = максимальная ширина капсулы: тексту есть куда переноситься.
    private static let width: CGFloat = 560
    /// Запас по высоте под три строки превью; капсула прижата к низу окна, остальное прозрачно.
    private static let height: CGFloat = 180
    /// Отступ капсулы от нижнего края экрана.
    private static let bottomInset: CGFloat = 80
    /// Небольшая задержка на скрытии, чтобы «✓ Вставлено» не мигало.
    private static let hideDelay: Duration = .milliseconds(300)

    private let panel: NSPanel
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?

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

        // Показ/скрытие зависит только от «idle или нет» — на потоке live-текста и уровня
        // (~12 обновлений в секунду) окно не трогаем.
        cancellable = controller.$state
            .map { state in
                if case .idle = state { return false }
                return true
            }
            .removeDuplicates()
            .sink { [weak self] visible in
                // `state` мутируется только на MainActor (DictationController — @MainActor).
                MainActor.assumeIsolated { self?.setVisible(visible) }
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

    private func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: Self.hideDelay)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
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
