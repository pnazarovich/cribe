import AppKit
import SwiftUI

/// Перелёт капсулы в карточку каплей: капсула собирается, отрывается каплей, разгоняясь
/// падает по дуге влево-вниз и растекается в карточку.
///
/// Две отдельные панели одним движением не анимируются, поэтому на время перелёта между
/// ними живёт третье, служебное окно: в нём и едет фигура. Мышь оно не принимает, ключевым
/// не становится и снимается сразу после посадки. Доставку текста перелёт не задерживает
/// ни на миллисекунду — текст уже в буфере и в модели карточки, летят только пиксели.
@MainActor
enum CardFlight {
    // MARK: - Хронометраж

    /// Сбор: содержимое капсулы гаснет, сама она подбирается — поверхностное натяжение.
    static let gather: TimeInterval = 0.18
    /// Отрыв: тело перехватывает шейку и вытягивает хвост — получается капля.
    static let detach: TimeInterval = 0.12
    /// Падение: разгон по дуге. Именно этот участок и просили — медленно, потом быстрее.
    static let fall: TimeInterval = 0.32
    /// Посадка: капля растекается в силуэт карточки с мягким перелётом.
    static let land: TimeInterval = 0.13
    /// Весь перелёт целиком.
    static let duration: TimeInterval = gather + detach + fall + land
    /// Последний участок: карточка проявляется, летящая фигура тает. Обе половины стыка
    /// идут одной длительностью — иначе на кадре виден провал.
    static let handoff: TimeInterval = 0.10

    /// Пружина посадки: ширина слегка перелетает и оседает — одна волна, не дрожь.
    static let landResponse: Double = 0.18
    static let landDamping: Double = 0.7

    /// Летим ли вообще. При «Уменьшить движение» перелёта нет — и тогда капсула ОБЯЗАНА
    /// сказать «⤷ В карточку» сама: другого ответа пользователю не остаётся.
    static var flies: Bool { !HUDAccessibility.shared.reduceMotion }

    /// Служебное окно живёт чуть дольше самого перелёта: снять его ровно в конце — значит
    /// обрезать затухание.
    private static let windowLinger: Duration = .milliseconds(120)

    /// Запас вокруг фигуры внутри служебного окна: в нём помещаются провис дуги, хвост
    /// капли и перелёт пружины за точку приземления.
    private static let bleed: CGFloat = 90

    // MARK: - Геометрия (её и проверяет тест)

    /// Прямоугольник служебного окна: объединение старта и финиша плюс запас.
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

    /// Точка на дуге падения. Квадратичная кривая Безье: опорная точка утянута влево-вниз,
    /// поэтому капля не режет угол по прямой, а падает дугой.
    static func point(on progress: CGFloat, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let control = controlPoint(from: start, to: end)
        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * progress * control.x + progress * progress * end.x,
            y: inverse * inverse * start.y + 2 * inverse * progress * control.y + progress * progress * end.y
        )
    }

    /// Опорная точка дуги: середина пути, сдвинутая ещё дальше влево и ниже — капля сперва
    /// уходит вбок, и только потом её забирает вниз.
    static func controlPoint(from start: CGPoint, to end: CGPoint) -> CGPoint {
        CGPoint(
            x: start.x - (start.x - end.x) * 0.75,
            y: start.y + (end.y - start.y) * 0.35
        )
    }

    /// Угол касательной к дуге в точке `progress` — по нему капля и разворачивается,
    /// иначе хвост торчал бы не туда.
    static func angle(on progress: CGFloat, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let control = controlPoint(from: start, to: end)
        let inverse = 1 - progress
        let dx = 2 * inverse * (control.x - start.x) + 2 * progress * (end.x - control.x)
        let dy = 2 * inverse * (control.y - start.y) + 2 * progress * (end.y - control.y)
        // Голова капли смотрит ВЛЕВО, поэтому нулевой угол — это движение влево.
        return atan2(dy, dx) - .pi
    }

    // MARK: - Полёт

    /// Пускает перелёт. `landed` вызывается за `handoff` до конца — в этот момент
    /// показывается настоящая карточка, и последние кадры они идут вместе.
    ///
    /// При «Уменьшить движение» перелёта нет вовсе: `landed` зовётся сразу.
    static func fly(from source: CGRect, to target: CGRect, landed: @escaping () -> Void) {
        guard flies else {
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

        Task { @MainActor in
            // 1. Сбор: содержимое гаснет, капсула подбирается по бокам и вспухает по высоте.
            withAnimation(.easeOut(duration: gather)) { model.stage = .gathering }
            try? await Task.sleep(for: .seconds(gather))

            // 2. Отрыв: шейка перехватывается, вытягивается хвост — это уже капля.
            withAnimation(.easeInOut(duration: detach)) { model.stage = .droplet }
            try? await Task.sleep(for: .seconds(detach))

            // 3. Падение с разгоном: кубика с тяжёлым входом (медленно → быстро).
            withAnimation(.timingCurve(0.55, 0.055, 0.675, 0.19, duration: fall)) { model.travel = 1 }
            try? await Task.sleep(for: .seconds(fall))

            // 4. Посадка: капля растекается в карточку с одной мягкой волной.
            withAnimation(.spring(response: landResponse, dampingFraction: landDamping)) {
                model.stage = .landed
            }
            try? await Task.sleep(for: .seconds(land - handoff))

            // 5. Стык: настоящая карточка проявляется, летящая фигура тает.
            landed()
            withAnimation(.easeIn(duration: handoff)) { model.faded = true }
            try? await Task.sleep(for: windowLinger)
            panel.orderOut(nil)
        }
    }
}

/// Ступени перелёта. Форму капли на каждой из них задаёт `FlightView`.
enum FlightStage {
    case capsule
    case gathering
    case droplet
    case landed
}

/// Состояние летящей фигуры: ступень, доля пути и растворение на стыке.
@MainActor
private final class FlightModel: ObservableObject {
    let start: CGRect
    let finish: CGRect

    @Published var stage: FlightStage = .capsule
    @Published var travel: CGFloat = 0
    @Published var faded = false

    init(start: CGRect, finish: CGRect) {
        self.start = start
        self.finish = finish
    }
}

/// Летящая фигура целиком: форма, положение на дуге, разворот по касательной и растяжение
/// по ходу движения (классические «сплющить-растянуть»: чем быстрее, тем длиннее).
private struct FlightView: View {
    @ObservedObject var model: FlightModel

    /// Габарит капли в полёте.
    private static let dropletSide: CGFloat = 54

    private var shape: Droplet {
        switch model.stage {
        case .capsule:
            return Droplet(
                width: model.start.width,
                height: model.start.height,
                corner: model.start.height / 2,
                tail: 0,
                neck: 1
            )
        case .gathering:
            // Поверхностное натяжение: капсула сужается и чуть вспухает по высоте.
            return Droplet(
                width: model.start.width * 0.78,
                height: model.start.height * 1.12,
                corner: model.start.height / 2,
                tail: 0,
                neck: 1
            )
        case .droplet:
            return Droplet(
                width: Self.dropletSide,
                height: Self.dropletSide,
                corner: Self.dropletSide / 2,
                tail: Self.dropletSide * 0.75,
                neck: 0.34
            )
        case .landed:
            return Droplet(
                width: model.finish.width,
                height: model.finish.height,
                corner: CardMetrics.corner,
                tail: 0,
                neck: 1
            )
        }
    }

    /// Разгон читается растяжением: к концу падения капля длиннее и тоньше.
    private var stretch: CGSize {
        guard model.stage == .droplet else { return CGSize(width: 1, height: 1) }
        return CGSize(width: 1 + 0.35 * model.travel, height: 1 - 0.16 * model.travel)
    }

    private var center: CGPoint {
        CardFlight.point(
            on: model.travel,
            from: CGPoint(x: model.start.midX, y: model.start.midY),
            to: CGPoint(x: model.finish.midX, y: model.finish.midY)
        )
    }

    private var rotation: Angle {
        // На старте и на посадке фигура стоит ровно: разворот нужен только в падении.
        guard model.stage == .droplet else { return .zero }
        return .radians(
            Double(CardFlight.angle(
                on: model.travel,
                from: CGPoint(x: model.start.midX, y: model.start.midY),
                to: CGPoint(x: model.finish.midX, y: model.finish.midY)
            ))
        )
    }

    var body: some View {
        let form = shape
        return form
            // Жидкость: тёмное стекло с кантом и бликом у ведущей кромки.
            .fill(Color(white: 0.16).opacity(0.72))
            .overlay { form.stroke(.white.opacity(0.32), lineWidth: 1) }
            .overlay { highlight.mask { form } }
            .frame(width: max(model.start.width, model.finish.width) + 160,
                   height: max(model.start.height, model.finish.height) + 160)
            .scaleEffect(x: stretch.width, y: stretch.height)
            .rotationEffect(rotation)
            .position(center)
            .opacity(model.faded ? 0 : 1)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .environment(\.colorScheme, .dark)
    }

    /// Внутренний блик: на сборе он съезжает к ведущей (левой) кромке — так читается,
    /// что жидкость собирается именно туда, куда сейчас полетит.
    private var highlight: some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.30), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 30, height: 16)
            .offset(x: model.stage == .capsule ? 0 : -18, y: -6)
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
