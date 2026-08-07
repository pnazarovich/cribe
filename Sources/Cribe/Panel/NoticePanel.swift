import AppKit
import SwiftUI
import CribeCore

/// Записка над пилюлей: одна строка, которая сама приезжает и сама уходит.
///
/// Зачем отдельное окно. Пилюля показывает ОДНО дело, а с наложением их бывает два сразу:
/// пока пишется новая диктовка, доезжает прошлая. Всё, что пилюля в такой момент сказать
/// не может, — отказ на полной очереди, разовая подсказка про наложение, оговорка или сбой
/// уже доехавшей диктовки — уходит сюда. Иначе оно просто пропало бы, а молчаливый отказ
/// хуже любого сообщения.
///
/// Системное уведомление тут не годится: оно уводит фокус в Центр уведомлений и живёт
/// дольше повода. Эта записка не кликается вовсе (`ignoresMouseEvents`), не становится key
/// и гаснет сама.
@MainActor
public final class NoticePanel {

    /// Ширина с запасом на две строки текста и на мягкую тень по краям.
    private static let width: CGFloat = 460
    private static let height: CGFloat = 76
    /// Над пилюлей: та стоит на 80 pt от низа в окне высотой 92 — записка встаёт над ней,
    /// не закрывая ни её, ни карточки в левом нижнем углу.
    private static let bottomInset: CGFloat = 176
    /// Сколько записка висит. Хватает прочитать одну строку и не мешает работать.
    private static let linger: Duration = .seconds(4.5)
    /// Плашка живёт, пока доигрывает уход.
    private static let exitDuration: Duration = .milliseconds(300)

    /// Не `let`: оболочка окна меняется на каждом показе (см. `HUDWindow.renew`).
    private var panel: NSPanel
    private let presentation = NoticePresentation()
    private var hideTask: Task<Void, Never>?

    public init() {
        panel = Self.makeShell()
        panel.contentView = NSHostingView(rootView: NoticeView(presentation: presentation))
    }

    /// Оболочка окна записки — без содержимого: его строит `init` один раз и дальше оно
    /// переезжает из оболочки в оболочку.
    private static func makeShell() -> NSPanel {
        let panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = HUDWindow.level
        panel.collectionBehavior = HUDWindow.spaceBehavior.union(.stationary)
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень рисует SwiftUI по форме плашки, а не система по прямоугольнику окна.
        panel.hasShadow = false
        panel.animationBehavior = .utilityWindow
        // Записка ничего не предлагает нажать — клики обязаны доходить до окна под ней.
        panel.ignoresMouseEvents = true
        return panel
    }

    /// Показывает строку. Вторая записка подряд заменяет первую и продлевает показ:
    /// две плашки друг над другом — это уже панель, а HIG требует держать HUD маленьким.
    public func show(_ text: String) {
        guard !text.isEmpty else { return }
        hideTask?.cancel()
        presentation.text = text
        // Свежая оболочка на каждый показ — по той же причине, что и у пилюли: прописка
        // во всех пространствах у прожившего часами окна протухает (см. `HUDWindow`).
        // Видимое окно не трогаем: вторая записка подряд заменяет первую на месте.
        if !panel.isVisible { panel = HUDWindow.renew(panel) { Self.makeShell() } }
        moveToCursorScreen()
        HUDWindow.orderFront(panel, extra: .stationary)
        withAnimation(Self.appearAnimation) { presentation.isVisible = true }

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled, let self else { return }
            withAnimation(Self.disappearAnimation) { self.presentation.isVisible = false }
            try? await Task.sleep(for: Self.exitDuration)
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
            self.hideTask = nil
        }
    }

    /// Тот же словарь движения, что у живой панели: приезд пружиной, уход без неё.
    private static var appearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.35, dampingFraction: 0.72)
    }

    private static var disappearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }

    /// Тот же экран, что и у пилюли: низ по центру экрана с курсором.
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

/// Что записка показывает прямо сейчас.
@MainActor
private final class NoticePresentation: ObservableObject {
    @Published var isVisible = false
    @Published var text = ""
}

private struct NoticeView: View {
    @ObservedObject var presentation: NoticePresentation

    @ObservedObject private var accessibility = HUDAccessibility.shared

    var body: some View {
        Group {
            if presentation.isVisible {
                NoticeCapsule(text: presentation.text)
                    .transition(accessibility.reduceMotion ? .opacity : .notice)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Кадр появления записки: она оседает сверху вниз — навстречу пилюле, которая всплывает
/// снизу. Разное направление и отличает «сообщение о работе» от «сообщения про работу».
private struct NoticePhase: ViewModifier {
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: offset).opacity(opacity)
    }
}

extension AnyTransition {
    fileprivate static let notice = AnyTransition.modifier(
        active: NoticePhase(offset: -8, opacity: 0),
        identity: NoticePhase(offset: 0, opacity: 1)
    )
}

/// Плашка записки. Стекло, форма и тени — общие с пилюлей (`GlassStyle`), потому что это
/// одна и та же поверхность продукта; отличается только содержимое и направление приезда.
private struct NoticeCapsule: View {
    let text: String

    @ObservedObject private var accessibility = HUDAccessibility.shared

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 400)
            .fixedSize(horizontal: true, vertical: false)
            .background { GlassPlate(shape: Capsule()) }
            .overlay { GlassRim(shape: Capsule()) }
            .overlay { GlassSheen(shape: Capsule()) }
            .compositingGroup()
            .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
            .shadow(color: .black.opacity(0.20), radius: 2.5, y: 1)
            // Схема фиксированно тёмная — та же причина, что у пилюли: только она читается
            // и над белым документом, и над видео.
            .environment(\.colorScheme, .dark)
            .accessibilityLabel(text)
    }
}

/// Записка не должна забирать фокус ни при каких обстоятельствах: она появляется прямо
/// во время диктовки, а увести фокус — значит увести и вставку из целевого поля.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Что именно написано в записке. Ядро называет только повод (`DictationNotice`) — слова
/// живут здесь, рядом с поверхностью, которая их показывает.
enum NoticeText {
    /// Пустая строка означает «показывать нечего»: `NoticePanel.show` такую не покажет.
    static func line(for notice: DictationNotice, hotkey: HotkeyMode) -> String {
        switch notice {
        case .queueFull(let limit):
            return "Уже \(limit) диктовки в работе — дождитесь, пока доедет первая"
        case .parallelHint:
            // Про клавишу говорим ровно то, что у человека настроено: «жмите ⌘» при своём
            // шорткате было бы прямой ложью.
            let key = hotkey == .rightCommand ? "правый ⌘" : "хоткей диктовки"
            return "Не ждите обработки: нажмите \(key) и говорите дальше"
        case .result(let state):
            return resultLine(state)
        }
    }

    /// Итог диктовки, которому не хватило пилюли. Показываем только то, о чём человек
    /// обязан узнать: удачную вставку он и так видит по появившемуся тексту.
    private static func resultLine(_ state: DictationState) -> String {
        switch state {
        case .cancelled: return "Запись отменена"
        case .degraded(let reason): return "⚠️ \(reason)"
        case .error(let message): return "⚠️ \(message)"
        case .idle, .preparingModel, .recording, .transcribing, .cleaning, .inserted, .carded:
            return ""
        }
    }
}
