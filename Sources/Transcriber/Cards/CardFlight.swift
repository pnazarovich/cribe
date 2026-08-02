import AppKit
import SwiftUI

/// Перелёт пилюли в карточку: капсула HUD не гаснет на месте, а уезжает влево-вниз, по
/// дороге превращаясь в силуэт карточки, и в точке приземления её сменяет настоящая
/// карточка. Смена делается перекрёстным затуханием, поэтому шва не видно.
///
/// Две разные панели анимировать одним движением нельзя — поэтому между ними на время
/// перелёта живёт третье, служебное окно: в нём и едет фигура. Оно не принимает мышь,
/// не становится ключевым и снимается сразу после посадки.
@MainActor
enum CardFlight {
    /// Длительность перелёта. Пружина тех же чисел, что у появления пилюли, только чуть
    /// длиннее: путь через весь экран короткая пружина проходит рывком.
    static let duration: TimeInterval = 0.42
    static let response: Double = 0.42
    static let dampingFraction: Double = 0.78
    /// Последний участок: летящая фигура растворяется, настоящая карточка проявляется.
    /// Обе половины стыка идут одной длительностью — иначе на кадре виден провал.
    static let handoff: TimeInterval = 0.12

    /// Служебное окно живёт чуть дольше самого перелёта: снять его ровно в конце — значит
    /// обрезать затухание.
    private static let windowLinger: Duration = .milliseconds(120)

    /// Запас вокруг фигуры внутри служебного окна: в нём помещаются тень и «перелёт»
    /// пружины за точку приземления.
    private static let bleed: CGFloat = 40

    /// Прямоугольник служебного окна: объединение старта и финиша плюс запас.
    /// Чистая геометрия — её и проверяет тест.
    static func windowFrame(from source: CGRect, to target: CGRect) -> CGRect {
        source.union(target).insetBy(dx: -bleed, dy: -bleed)
    }

    /// Прямоугольник в координатах служебного окна (начало координат слева СВЕРХУ:
    /// SwiftUI внутри окна работает во флипнутой системе).
    static func local(_ rect: CGRect, in window: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - window.minX,
            y: window.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Пускает перелёт. `landed` вызывается за `handoff` до конца — в этот момент
    /// показывается настоящая карточка, и последние кадры они идут вместе.
    ///
    /// При «Уменьшить движение» перелёта нет вовсе: карточка просто появляется, а пилюля
    /// гаснет — `landed` зовётся сразу.
    static func fly(from source: CGRect, to target: CGRect, landed: @escaping () -> Void) {
        guard !HUDAccessibility.shared.reduceMotion else {
            landed()
            return
        }

        let frame = windowFrame(from: source, to: target)
        let model = FlightModel(
            start: local(source, in: frame),
            finish: local(target, in: frame)
        )
        let panel = FlightPanel(contentRect: frame)
        panel.contentView = NSHostingView(rootView: FlightView(model: model))
        HUDWindow.orderFront(panel)

        // Первый кадр окно должно показать фигуру НА СТАРТЕ, иначе пружина поедет из
        // ниоткуда: движение запускаем следующим тиком.
        Task { @MainActor in
            withAnimation(.spring(response: response, dampingFraction: dampingFraction)) {
                model.arrived = true
            }
            try? await Task.sleep(for: .seconds(duration - handoff))
            landed()
            withAnimation(.easeIn(duration: handoff)) { model.faded = true }
            try? await Task.sleep(for: windowLinger)
            panel.orderOut(nil)
        }
    }
}

/// Состояние летящей фигуры. Два флага — весь перелёт: «доехала» ведёт форму и положение,
/// «растворилась» — стык с настоящей карточкой.
@MainActor
private final class FlightModel: ObservableObject {
    let start: CGRect
    let finish: CGRect

    @Published var arrived = false
    @Published var faded = false

    init(start: CGRect, finish: CGRect) {
        self.start = start
        self.finish = finish
    }
}

/// Летящая фигура: то же стекло, что у пилюли и карточки, поэтому подмены не видно.
/// Скругление едет вместе с габаритом — от капсулы (половина высоты) к углу карточки.
private struct FlightView: View {
    @ObservedObject var model: FlightModel

    private var rect: CGRect { model.arrived ? model.finish : model.start }

    private var corner: CGFloat {
        model.arrived ? CardMetrics.corner : model.start.height / 2
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return shape
            .fill(Color.clear)
            .background { GlassPlate(shape: shape, cornerRadius: corner) }
            .overlay { GlassRim(shape: shape) }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(model.faded ? 0 : 1)
            .environment(\.colorScheme, .dark)
    }
}

/// Окно перелёта: сквозное для мыши и никогда не ключевое — оно живёт доли секунды и
/// не должно ни ловить клики, ни трогать фокус.
private final class FlightPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = HUDWindow.level
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
