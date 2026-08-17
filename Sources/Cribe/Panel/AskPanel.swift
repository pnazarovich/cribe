import AppKit
import OSLog
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
    private var current: (AskPrompt, (Bool) -> Void)?
    private var queue: [(AskPrompt, (Bool) -> Void)] = []

    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Panel")

    public init() {
        panel = Self.makeShell(width: AskLayout.maximumWidth)
        install()
    }

    /// Сколько вопросов сейчас на руках: показанный плюс ждущие своей очереди.
    var waiting: Int { queue.count + (current == nil ? 0 : 1) }

    /// Спросить про одну правку. Ответ уходит в `reply` ровно один раз — либо `true`, либо
    /// `false`. Если человек не ответил, `reply` не зовётся вовсе: молчание не решение.
    ///
    /// Вопросы идут по одному. Про одну и ту же пару дважды не спрашиваем: диктовка могла
    /// повториться, пока прошлый вопрос ещё висит.
    public func ask(_ request: LearnRequest, reply: @escaping (Bool) -> Void) {
        ask(AskPrompt(request), reply: reply)
    }

    /// Тот же вопрос, но повод произвольный: плашка одна на все случаи, когда надо нажать.
    public func ask(_ prompt: AskPrompt, reply: @escaping (Bool) -> Void) {
        guard current?.0 != prompt, !queue.contains(where: { $0.0 == prompt }) else { return }
        queue.append((prompt, reply))
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
        presentation.prompt = item.0

        // Окно строится заново на каждый вопрос, и порядок здесь не вкусовой: сначала
        // размер, и только потом содержимое. Наоборот было — и не работало вовсе. Окно
        // кроится по длине пары, а менять размер окну, в котором уже живёт SwiftUI,
        // значит стравить две раскладки: AppKit насчитывает по десятку проходов на кадр,
        // упирается в собственный предел («limit: 8») и бросает окно недосчитанным.
        // Пустое место на экране — весь итог. У записки этой беды нет ровно потому, что
        // её окно всегда одного размера.
        panel.orderOut(nil)
        panel = Self.makeShell(width: Self.capsuleWidth(for: item.0) + Self.margin * 2)
        place()
        install()
        HUDWindow.orderFront(panel, extra: .stationary)
        withAnimation(Self.appearAnimation) { presentation.isVisible = true }
        Self.logger.notice(
            """
            Вопрос о правке показан: \(Int(self.panel.frame.width), privacy: .public)×\
            \(Int(self.panel.frame.height), privacy: .public) в \
            (\(Int(self.panel.frame.minX), privacy: .public), \
            \(Int(self.panel.frame.minY), privacy: .public)), \
            на экране=\(self.panel.isVisible ? "да" : "нет", privacy: .public)
            """
        )

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            // Никто не ответил: вопрос уходит, ничего не решив. В следующий раз спросят снова.
            self?.answer(nil)
        }
    }

    /// `nil` — вопрос истёк сам. Ответ уходит только на нажатие.
    ///
    /// Неотвеченный вопрос уносит с собой и всю очередь. Молчание значит, что человек
    /// на экран не смотрит, — и показывать ему следом ещё четыре плашки бессмысленно:
    /// это уже не вопрос, а навязчивость. Ничего при этом не теряется: пары не отвергнуты,
    /// а ошибка распознавания, которая их породила, повторится и спросит снова.
    func answer(_ accepted: Bool?) {
        guard let item = current else { return }
        current = nil
        hideTask?.cancel()
        hideTask = nil
        if let accepted {
            item.1(accepted)
        } else if !queue.isEmpty {
            Self.logger.notice(
                "Вопрос о правке остался без ответа — снимаем и остальные \(self.queue.count, privacy: .public)"
            )
            queue.removeAll()
        }

        withAnimation(Self.disappearAnimation) { presentation.isVisible = false }
        Task { [weak self] in
            try? await Task.sleep(for: Self.exitDuration)
            guard let self else { return }
            panel.orderOut(nil)
            showNext()
        }
    }

    /// Низ по центру экрана, на котором сейчас курсор. Только место: размер окно получило
    /// при рождении и больше не меняется.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrameOrigin(
            NSPoint(
                x: (screen.frame.midX - panel.frame.width / 2).rounded(),
                y: (screen.frame.minY + Self.bottomInset).rounded()
            )
        )
    }

    /// Ширина плашки под конкретную пару.
    ///
    /// Считается заранее и тем же шрифтом, каким рисует SwiftUI: окно кроится по плашке,
    /// и разъехаться им нельзя — иначе текст обрежется краем окна.
    static func capsuleWidth(for request: LearnRequest) -> CGFloat {
        capsuleWidth(for: AskPrompt(request))
    }

    static func capsuleWidth(for prompt: AskPrompt) -> CGFloat {
        let width = AskLayout.leading
            + AskLayout.width(prompt.question, font: AskLayout.questionFont)
            + AskLayout.gap
            + AskLayout.buttonWidth(prompt.accept)
            + AskLayout.buttonGap
            + AskLayout.buttonWidth(prompt.refuse)
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

    private static func makeShell(width: CGFloat) -> NSPanel {
        let panel = NonKeyAskPanel(
            contentRect: NSRect(x: 0, y: 0, width: width.rounded(), height: capsuleHeight + margin * 2),
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
/// О чём спрашивает плашка. Поводов два — пополнить словарь и повторить чистку, — а
/// поверхность одна: окно с кнопками стоит дорого (см. кройку окна выше), и второй такой
/// заводить незачем.
public struct AskPrompt: Equatable, Sendable {
    public let question: String
    public let accept: String
    public let refuse: String

    public init(question: String, accept: String, refuse: String) {
        self.question = question
        self.accept = accept
        self.refuse = refuse
    }

    /// Вопрос о словаре.
    ///
    /// Названо ровно то слово, которое человек видел на экране и правил своими руками.
    /// Услышанное распознаванием в вопросе не участвует, хотя в словарь уедет именно оно:
    /// человеку нет дела до внутренней кухни, а слово, которого он в глаза не видел,
    /// превращает понятный вопрос в загадку.
    public init(_ request: LearnRequest) {
        let shown = request.edited ?? request.correction.heard
        self.init(
            question: "Вы исправили «\(shown)» на «\(request.correction.meant)». В словарь?",
            accept: "Добавить",
            refuse: "Нет"
        )
    }

    /// Предложение повторить не удавшуюся чистку.
    public static let retryCleanup = AskPrompt(
        question: "Текст вставлен без AI-чистки. Сделать ещё раз?",
        accept: "Ещё раз",
        refuse: "Не надо"
    )
}

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

    /// Слова вопроса о словаре — оставлены здесь ради тестов, которые их и проверяют.
    static let accept = "Добавить"
    static let refuse = "Нет"

    static func question(_ request: LearnRequest) -> String { AskPrompt(request).question }

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
    @Published var prompt: AskPrompt?
}

private struct AskView: View {
    @ObservedObject var presentation: AskPresentation
    let answer: (Bool) -> Void

    @ObservedObject private var accessibility = HUDAccessibility.shared

    var body: some View {
        Group {
            if presentation.isVisible, let prompt = presentation.prompt {
                AskCapsule(prompt: prompt, answer: answer)
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
    let prompt: AskPrompt
    let answer: (Bool) -> Void

    var body: some View {
        HStack(spacing: AskLayout.gap) {
            Text(prompt.question)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            HStack(spacing: AskLayout.buttonGap) {
                AskButton(title: prompt.accept, prominent: true) { answer(true) }
                AskButton(title: prompt.refuse, prominent: false) { answer(false) }
            }
        }
        .padding(.leading, AskLayout.leading)
        .padding(.trailing, AskLayout.trailing)
        .frame(height: 44)
        // Собственный размер плашки ограничен так же, как у записки: окно скроено по нему,
        // и расти сверх него плашке нельзя — иначе она снова начнёт спорить с окном.
        .frame(maxWidth: AskLayout.maximumWidth)
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
