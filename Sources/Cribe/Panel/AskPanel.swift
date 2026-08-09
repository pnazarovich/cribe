import AppKit
import SwiftUI
import CribeCore

/// Вопрос над пилюлей: «вот это я услышал не так — запомнить?».
///
/// Единственное место, где словарь пополняется правкой человека. Молча этого не делает
/// никто: пара применяется ко ВСЕМ будущим диктовкам, и цена ошибки несимметрична —
/// пропущенную человек добавит руками, а лишняя тихо портит каждую следующую фразу.
/// Судья (`DictionaryJudge`) поэтому только предлагает, а решают здесь.
///
/// Стекло, форма и движение — общие с запиской (`NoticePanel`), потому что это одна и та же
/// поверхность продукта. Отличие ровно одно: сюда можно нажать. Оттого и окно кроится по
/// самой плашке, а не берётся с запасом: невидимый прямоугольник, который перехватывает
/// клики, — худшее, что HUD может сделать с чужим окном под собой.
@MainActor
public final class AskPanel {

    /// Высота плашки с кнопками и запас на мягкую тень по краям.
    private static let capsuleHeight: CGFloat = 44
    private static let margin: CGFloat = 24
    /// Над пилюлей — там же, где записка.
    private static let bottomInset: CGFloat = 176
    /// Сколько вопрос ждёт ответа. Хватает заметить и решить, но не настолько долго, чтобы
    /// плашка стала частью пейзажа.
    private static let linger: Duration = .seconds(20)
    private static let exitDuration: Duration = .milliseconds(300)

    /// Не `let`: оболочка окна меняется на каждом показе (см. `HUDWindow.renew`).
    private var panel: NSPanel
    private let presentation = AskPresentation()
    private var hideTask: Task<Void, Never>?
    /// Вопрос на экране и очередь тех, что ждут своей очереди: две плашки друг над другом —
    /// это уже панель, а решать проще по одному.
    private var current: (Correction, (Bool) -> Void)?
    private var queue: [(Correction, (Bool) -> Void)] = []

    public init() {
        panel = Self.makeShell()
        install()
    }

    /// Спросить про одну правку. Ответ уходит в `reply` ровно один раз — либо `true`, либо
    /// `false`. Если человек не ответил, `reply` не зовётся вовсе: молчание не решение.
    public func ask(_ correction: Correction, reply: @escaping (Bool) -> Void) {
        queue.append((correction, reply))
        showNext()
    }

    private func install() {
        panel.contentView = FirstMouseHostingView(
            rootView: AskView(presentation: presentation) { [weak self] accepted in
                self?.answer(accepted)
            }
        )
    }

    private func showNext() {
        guard current == nil, !queue.isEmpty else { return }
        let item = queue.removeFirst()
        current = item
        presentation.correction = item.0

        // Свежая оболочка на каждый показ — по той же причине, что и у пилюли: прописка
        // во всех пространствах у прожившего часами окна протухает (см. `HUDWindow`).
        if !panel.isVisible {
            panel = HUDWindow.renew(panel) { Self.makeShell() }
            install()
        }
        place(for: item.0)
        HUDWindow.orderFront(panel, extra: .stationary)
        withAnimation(Self.appearAnimation) { presentation.isVisible = true }

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            // Никто не ответил: вопрос уходит, ничего не решив. В следующий раз спросят снова.
            self?.answer(nil)
        }
    }

    /// `nil` — вопрос истёк сам. Ответ уходит только на нажатие.
    private func answer(_ accepted: Bool?) {
        guard let item = current else { return }
        current = nil
        hideTask?.cancel()
        hideTask = nil
        if let accepted { item.1(accepted) }

        withAnimation(Self.disappearAnimation) { presentation.isVisible = false }
        Task { [weak self] in
            try? await Task.sleep(for: Self.exitDuration)
            guard let self else { return }
            panel.orderOut(nil)
            showNext()
        }
    }

    /// Окно ровно по плашке: клики мимо неё обязаны доходить до окна под ней.
    private func place(for correction: Correction) {
        let width = Self.capsuleWidth(for: correction) + Self.margin * 2
        let height = Self.capsuleHeight + Self.margin * 2
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrame(
            NSRect(
                x: (screen.frame.midX - width / 2).rounded(),
                y: (screen.frame.minY + Self.bottomInset).rounded(),
                width: width.rounded(),
                height: height
            ),
            display: false
        )
    }

    /// Ширина плашки под конкретную пару.
    ///
    /// Считается заранее и тем же шрифтом, каким рисует SwiftUI: окно кроится по плашке,
    /// и разъехаться им нельзя — иначе текст обрежется краем окна.
    static func capsuleWidth(for correction: Correction) -> CGFloat {
        let question = AskLayout.question(correction)
        let width = AskLayout.leading
            + AskLayout.width(question, font: AskLayout.questionFont)
            + AskLayout.gap
            + AskLayout.buttonWidth(AskLayout.accept)
            + AskLayout.buttonGap
            + AskLayout.buttonWidth(AskLayout.refuse)
            + AskLayout.trailing
        return min(width, AskLayout.maximumWidth)
    }

    /// Тот же словарь движения, что у пилюли и записки: приезд пружиной, уход без неё.
    private static var appearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.35, dampingFraction: 0.72)
    }

    private static var disappearAnimation: Animation {
        HUDAccessibility.shared.reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)
    }

    private static func makeShell() -> NSPanel {
        let panel = NonKeyAskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: capsuleHeight + margin * 2),
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
        return panel
    }
}

/// Размеры и слова вопроса. Вынесены отдельно, потому что нужны дважды: ими рисует SwiftUI
/// и по ним же кроится окно.
enum AskLayout {
    static let questionFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let buttonFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let leading: CGFloat = 16
    static let trailing: CGFloat = 8
    static let gap: CGFloat = 12
    static let buttonGap: CGFloat = 8
    static let buttonPadding: CGFloat = 12
    /// Дальше плашка не растёт: длинную пару лучше подрезать, чем растянуть на весь экран.
    static let maximumWidth: CGFloat = 720

    static let accept = "Добавить"
    static let refuse = "Нет"

    static func question(_ correction: Correction) -> String {
        "Услышал «\(correction.heard)», вы исправили на «\(correction.meant)». В словарь?"
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        // Пара точек запаса: измерение AppKit и раскладка SwiftUI сходятся не до пикселя.
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 2
    }

    static func buttonWidth(_ title: String) -> CGFloat {
        width(title, font: buttonFont) + buttonPadding * 2
    }
}

/// Что вопрос показывает прямо сейчас.
@MainActor
private final class AskPresentation: ObservableObject {
    @Published var isVisible = false
    @Published var correction: Correction?
}

private struct AskView: View {
    @ObservedObject var presentation: AskPresentation
    let answer: (Bool) -> Void

    @ObservedObject private var accessibility = HUDAccessibility.shared

    var body: some View {
        Group {
            if presentation.isVisible, let correction = presentation.correction {
                AskCapsule(correction: correction, answer: answer)
                    .transition(accessibility.reduceMotion ? .opacity : .ask)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Кадр появления: плашка оседает сверху вниз — навстречу пилюле, как и записка.
private struct AskPhase: ViewModifier {
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: offset).opacity(opacity)
    }
}

extension AnyTransition {
    fileprivate static let ask = AnyTransition.modifier(
        active: AskPhase(offset: -8, opacity: 0),
        identity: AskPhase(offset: 0, opacity: 1)
    )
}

private struct AskCapsule: View {
    let correction: Correction
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: AskLayout.gap) {
            Text(AskLayout.question(correction))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            HStack(spacing: AskLayout.buttonGap) {
                AskButton(title: AskLayout.accept, prominent: true) { answer(true) }
                AskButton(title: AskLayout.refuse, prominent: false) { answer(false) }
            }
        }
        .padding(.leading, AskLayout.leading)
        .padding(.trailing, AskLayout.trailing)
        .frame(height: 44)
        .background { GlassPlate(shape: Capsule()) }
        .overlay { GlassRim(shape: Capsule()) }
        .overlay { GlassSheen(shape: Capsule()) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
        .shadow(color: .black.opacity(0.20), radius: 2.5, y: 1)
        // Схема фиксированно тёмная — та же причина, что у пилюли: только она читается
        // и над белым документом, и над видео.
        .environment(\.colorScheme, .dark)
    }
}

private struct AskButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, AskLayout.buttonPadding)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(.white.opacity(fill))
                }
                .overlay {
                    Capsule().strokeBorder(.white.opacity(prominent ? 0.30 : 0.18), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }

    private var fill: Double {
        let base = prominent ? 0.20 : 0.08
        return hovering ? base + 0.10 : base
    }
}

/// Вопрос не должен забирать фокус: он появляется, пока человек уже пишет дальше, и увести
/// фокус значило бы увести его курсор из собственного текста.
private final class NonKeyAskPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Окно никогда не становится key и приложение не активирует, поэтому первый клик по кнопке
/// система отдала бы «на активацию» и потеряла. Здесь он обязан работать сразу.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required dynamic init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) не поддерживается")
    }
}
