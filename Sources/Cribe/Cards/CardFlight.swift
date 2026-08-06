import AppKit
import SwiftUI

/// Перелёт капсулы в карточку: капсула подбирается, отрывается, разгоняясь идёт по дуге
/// влево-вниз и растекается в карточку.
///
/// Форма всю дорогу одна — капсула. Никакой капли не рисуется: «жидкость» здесь делают
/// движение и пропорции. Тело удлиняется по ходу и на столько же утоньшается (площадь
/// почти не меняется), задняя кромка отстаёт на 30 мс и тянет за собой мягкий смаз, радиус
/// скругления по дороге доезжает до радиуса карточки — и уже на земле в рамку ПОСЛЕДНЕЙ
/// растекается ширина. Это и есть «как будто капля», а не капля.
///
/// Две отдельные панели одним движением не анимируются, поэтому на время перелёта между
/// ними живёт третье, служебное окно: в нём и едет фигура. Мышь оно не принимает, ключевым
/// не становится и снимается сразу после посадки. Доставку текста перелёт не задерживает
/// ни на миллисекунду — текст уже в буфере и в модели карточки, летят только пиксели.
@MainActor
enum CardFlight {
    // MARK: - Хронометраж

    /// Сбор: капсула подбирается по бокам и вспухает по высоте — поверхностное натяжение.
    static let gather: TimeInterval = 0.18
    /// Отрыв: тело подбирается в компактную капсулу — ту, что и полетит.
    static let detach: TimeInterval = 0.12
    /// Падение: разгон по дуге. Именно этот участок и просили — медленно, потом быстрее.
    static let fall: TimeInterval = 0.32
    /// Посадка: тело растекается в силуэт карточки с мягким перелётом.
    static let land: TimeInterval = 0.13
    /// Весь перелёт целиком.
    static let duration: TimeInterval = gather + detach + fall + land
    /// Последний участок: карточка проявляется, летящая фигура тает. Обе половины стыка
    /// идут одной длительностью — иначе на кадре виден провал.
    static let handoff: TimeInterval = 0.10

    /// Высота на посадке садится быстро и без пружины: она приезжает ПЕРВОЙ.
    static let landHeight: TimeInterval = land * 0.6
    /// Пружина посадки: ширина слегка перелетает и оседает — одна волна, не дрожь. Она же
    /// делает ширину последней: `landResponse` заведомо длиннее `landHeight`, и рамка
    /// «наливается» вширь уже после того, как всё остальное совпало с карточкой.
    static let landResponse: Double = 0.18
    static let landDamping: Double = 0.7

    /// Летим ли вообще. При «Уменьшить движение» перелёта нет — и тогда капсула ОБЯЗАНА
    /// сказать «⤷ В карточку» сама: другого ответа пользователю не остаётся.
    static var flies: Bool { !HUDAccessibility.shared.reduceMotion }

    /// Служебное окно живёт чуть дольше самого перелёта: снять его ровно в конце — значит
    /// обрезать затухание.
    private static let windowLinger: Duration = .milliseconds(120)

    /// Запас вокруг фигуры внутри служебного окна: в нём помещаются провис дуги, вытянутое
    /// тело со смазом и перелёт пружины за точку приземления.
    private nonisolated static let bleed: CGFloat = 90

    // MARK: - Пропорции тела

    /// Сбор: ужимается вширь и вспухает по высоте.
    static let gatherSqueeze: CGFloat = 0.78
    static let gatherSwell: CGFloat = 1.12
    /// Отрыв: габарит летящего тела. Дальше оно не сжимается — удлиняет его только разгон.
    static let flightSqueeze: CGFloat = 0.66
    static let flightSwell: CGFloat = 1.05

    /// Растяжение по ходу движения на полной скорости: длиннее в 1.35 и тоньше до 0.80.
    /// Площадь при этом почти держится (1.35 × 0.80 ≈ 1.08) — это «сплющить-растянуть»,
    /// а не рост фигуры.
    nonisolated static let maxStretch: CGFloat = 0.35
    nonisolated static let maxThinning: CGFloat = 0.20

    /// Потолок наклона. Касательная к концу дуги встаёт круче, но капсула, завалившаяся
    /// на полтора десятка градусов, читается уже не как та же самая пилюля, а как чужой
    /// предмет — поэтому наклон подрезан.
    nonisolated static let maxTilt: CGFloat = 12 * .pi / 180

    /// Задняя кромка идёт по той же кривой, но на 30 мс позже. Из этого отставания и
    /// растёт смаз позади тела.
    static let trailLag: TimeInterval = 0.03
    /// Дальше этого смаз за телом не уходит: оторвавшись, он читался бы вторым предметом.
    nonisolated static let trailReach: CGFloat = 22
    /// Размытие смаза. Больше трёх точек — уже не след, а вторая фигура.
    static let trailBlur: CGFloat = 3

    // MARK: - Геометрия (её и проверяет тест)
    //
    // Чистая математика без единого обращения к состоянию — и потому `nonisolated`:
    // её зовёт `FlightPlacement`, а `GeometryEffect` считает кадры вне главного актора.

    /// Прямоугольник служебного окна: объединение старта и финиша плюс запас.
    nonisolated static func windowFrame(from source: CGRect, to target: CGRect) -> CGRect {
        source.union(target).insetBy(dx: -bleed, dy: -bleed)
    }

    /// Прямоугольник в координатах служебного окна (начало координат слева СВЕРХУ:
    /// SwiftUI внутри окна работает во флипнутой системе).
    nonisolated static func local(_ rect: CGRect, in window: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - window.minX,
            y: window.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Точка на дуге падения. Квадратичная кривая Безье: опорная точка утянута влево-вниз,
    /// поэтому тело не режет угол по прямой, а падает дугой.
    nonisolated static func point(on progress: CGFloat, from start: CGPoint, to end: CGPoint) -> CGPoint {
        let control = controlPoint(from: start, to: end)
        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * progress * control.x + progress * progress * end.x,
            y: inverse * inverse * start.y + 2 * inverse * progress * control.y + progress * progress * end.y
        )
    }

    /// Опорная точка дуги: середина пути, сдвинутая ещё дальше влево и ниже — тело сперва
    /// уходит вбок, и только потом его забирает вниз.
    nonisolated static func controlPoint(from start: CGPoint, to end: CGPoint) -> CGPoint {
        CGPoint(
            x: start.x - (start.x - end.x) * 0.75,
            y: start.y + (end.y - start.y) * 0.35
        )
    }

    /// Растяжение на доле пути. Кубика разгона монотонна, поэтому доля пути работает и как
    /// доля скорости: чем быстрее, тем длиннее и тоньше.
    nonisolated static func stretch(at progress: CGFloat) -> CGSize {
        let clamped = min(max(progress, 0), 1)
        return CGSize(width: 1 + maxStretch * clamped, height: 1 - maxThinning * clamped)
    }

    /// Радиус скругления на доле пути: от половины высоты капсулы (полностью круглые торцы)
    /// до радиуса карточки. Единственное, чем силуэт вообще меняется за весь перелёт —
    /// и к посадке он уже совпал, поэтому на земле остаётся только растечься.
    nonisolated static func corner(at progress: CGFloat, from pill: CGFloat, to card: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return pill + (card - pill) * clamped
    }

    /// Наклон тела: угол касательной к дуге, приведённый к оси капсулы (она симметрична,
    /// поэтому угол и угол минус 180° — одно и то же) и подрезанный до `maxTilt`.
    nonisolated static func tilt(on progress: CGFloat, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let control = controlPoint(from: start, to: end)
        let inverse = 1 - progress
        let dx = 2 * inverse * (control.x - start.x) + 2 * progress * (end.x - control.x)
        let dy = 2 * inverse * (control.y - start.y) + 2 * progress * (end.y - control.y)
        var angle = atan2(dy, dx)
        if angle > .pi / 2 { angle -= .pi }
        if angle <= -.pi / 2 { angle += .pi }
        return min(max(angle, -maxTilt), maxTilt)
    }

    /// Сдвиг смаза относительно тела: назад по ходу, но не дальше `trailReach`.
    nonisolated static func trailOffset(lead: CGPoint, trail: CGPoint) -> CGSize {
        let dx = trail.x - lead.x
        let dy = trail.y - lead.y
        let distance = hypot(dx, dy)
        guard distance > trailReach else { return CGSize(width: dx, height: dy) }
        return CGSize(width: dx * trailReach / distance, height: dy * trailReach / distance)
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
            // 1. Сбор: капсула подбирается по бокам и вспухает по высоте. Радиус едет
            //    вместе с высотой — торцы остаются идеально круглыми.
            withAnimation(.easeOut(duration: gather)) {
                model.bodyWidth = model.start.width * gatherSqueeze
                model.bodyHeight = model.start.height * gatherSwell
            }
            try? await Task.sleep(for: .seconds(gather))

            // 2. Отрыв: тело подбирается в компактную капсулу и встаёт «в воздух» —
            //    с этого мгновения работают растяжение и наклон.
            withAnimation(.easeInOut(duration: detach)) {
                model.bodyWidth = model.start.width * flightSqueeze
                model.bodyHeight = model.start.height * flightSwell
                model.air = 1
            }
            try? await Task.sleep(for: .seconds(detach))

            // 3. Падение с разгоном: кубика с тяжёлым входом (медленно → быстро). По ней
            //    же едут растяжение, наклон и радиус — все они считаются из доли пути.
            withAnimation(fallCurve) { model.travel = 1 }
            // Задняя кромка выходит на 30 мс позже — ровно из этого отставания и берётся
            // смаз позади тела. Отдельным ожиданием, а не `.delay`: две анимации, поданные
            // в один такт, склеились бы в одну.
            try? await Task.sleep(for: .seconds(trailLag))
            withAnimation(fallCurve) { model.trail = 1 }
            try? await Task.sleep(for: .seconds(fall - trailLag))

            // 4. Посадка: сперва садится высота и гаснет растяжение, и только потом
            //    пружиной растекается ширина — радиус к этому моменту уже совпал.
            withAnimation(.easeOut(duration: landHeight)) {
                model.bodyHeight = model.finish.height
                model.air = 0
            }
            withAnimation(.spring(response: landResponse, dampingFraction: landDamping)) {
                model.bodyWidth = model.finish.width
            }
            try? await Task.sleep(for: .seconds(land - handoff))

            // 5. Стык: настоящая карточка проявляется, летящая фигура тает.
            landed()
            withAnimation(.easeIn(duration: handoff)) { model.faded = true }
            try? await Task.sleep(for: windowLinger)
            panel.orderOut(nil)
        }
    }

    /// Разгон падения: медленно, потом быстро.
    private static var fallCurve: Animation {
        .timingCurve(0.55, 0.055, 0.675, 0.19, duration: fall)
    }
}

/// Состояние летящей фигуры. Габарит и доли пути — отдельные числа, и это не педантизм:
/// только так ширина умеет оседать на посадке ПОЗЖЕ высоты, а задняя кромка — отставать
/// от передней.
@MainActor
private final class FlightModel: ObservableObject {
    let start: CGRect
    let finish: CGRect

    /// Габарит тела; радиус считается из доли пути и высоты.
    @Published var bodyWidth: CGFloat
    @Published var bodyHeight: CGFloat
    /// Доля пути ведущей кромки и отстающей.
    @Published var travel: CGFloat = 0
    @Published var trail: CGFloat = 0
    /// В воздухе: 1 — растяжение и наклон в полную силу, 0 — тело стоит ровно.
    @Published var air: CGFloat = 0
    @Published var faded = false

    init(start: CGRect, finish: CGRect) {
        self.start = start
        self.finish = finish
        bodyWidth = start.width
        bodyHeight = start.height
    }
}

/// Положение фигуры на дуге вместе с растяжением и наклоном.
///
/// Всё это обязано считаться из ОДНОГО анимируемого числа — доли пути: подставь SwiftUI
/// готовую точку, и она проведёт тело между старта и финиша по прямой, а дуга останется
/// только в тесте. Здесь же интерполируется скаляр, а точку на кривой считает каждый кадр.
private struct FlightPlacement: GeometryEffect {
    /// Доля пути ведущей кромки и отстающей.
    var travel: CGFloat
    var trail: CGFloat
    /// Насколько тело «в воздухе».
    var air: CGFloat
    let start: CGPoint
    let finish: CGPoint
    /// Смаз идёт по следу задней кромки; само тело — по ведущей.
    let smear: Bool

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(travel, AnimatablePair(trail, air)) }
        set {
            travel = newValue.first
            trail = newValue.second.first
            air = newValue.second.second
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let lead = CardFlight.point(on: travel, from: start, to: finish)
        var center = lead
        if smear {
            let offset = CardFlight.trailOffset(
                lead: lead,
                trail: CardFlight.point(on: trail, from: start, to: finish)
            )
            center = CGPoint(x: lead.x + offset.width, y: lead.y + offset.height)
        }
        // На земле (`air` = 0) растяжение и наклон вырождаются в единицу и ноль сами собой.
        let stretch = CardFlight.stretch(at: travel * air)
        let tilt = CardFlight.tilt(on: travel, from: start, to: finish) * air

        var transform = CGAffineTransform(translationX: center.x, y: center.y)
        transform = transform.rotated(by: tilt)
        transform = transform.scaledBy(x: stretch.width, y: stretch.height)
        transform = transform.translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

/// Летящая фигура целиком: капсула, её смаз и стекло поверх.
private struct FlightView: View {
    @ObservedObject var model: FlightModel

    /// Кадр, внутри которого рисуется тело: с запасом на растяжение и мягкую тень.
    private var box: CGSize {
        CGSize(
            width: max(model.start.width, model.finish.width) + 160,
            height: max(model.start.height, model.finish.height) + 160
        )
    }

    private var form: FlightCapsule {
        FlightCapsule(
            width: model.bodyWidth,
            height: model.bodyHeight,
            corner: CardFlight.corner(
                at: model.travel,
                from: model.bodyHeight / 2,
                to: CardMetrics.corner
            )
        )
    }

    var body: some View {
        // Выравнивание по левому верхнему углу: `FlightPlacement` двигает фигуру от начала
        // координат окна, и любое другое выравнивание сместило бы всю дугу.
        ZStack(alignment: .topLeading) {
            glass
            rim
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(model.faded ? 0 : 1)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .environment(\.colorScheme, .dark)
    }

    /// Стекло: тело и смаз, слитые в ОДНУ заливку, и только потом полупрозрачные.
    ///
    /// Порядок именно такой не из педантизма. Сделай оба силуэта полупрозрачными по
    /// отдельности — и на перекрытии выйдет тёмное пятно внутри фигуры; внутри капсулы
    /// не должно быть ничего: ни пятна, ни блика, ни второй формы, только ровное стекло.
    private var glass: some View {
        ZStack(alignment: .topLeading) {
            smear
            plate.modifier(placement(smear: false))
        }
        .compositingGroup()
        .opacity(0.72)
    }

    /// Смаз: та же капсула на следе задней кромки, размытая. Тело кроет её целиком, поэтому
    /// наружу выходит только мягкий край позади — «жидкость не поспевает за собой».
    private var smear: some View {
        plate
            .blur(radius: CardFlight.trailBlur)
            .modifier(placement(smear: true))
            .opacity(model.air * 0.6)
    }

    /// Кант — единственное, что рисуется поверх стекла: тонкая линия по самому краю.
    private var rim: some View {
        form
            .stroke(.white.opacity(0.32), lineWidth: 1)
            .frame(width: box.width, height: box.height)
            .modifier(placement(smear: false))
    }

    /// Сплошная заливка тела. Именно СПЛОШНАЯ: прозрачность даёт уже вся группа целиком.
    private var plate: some View {
        form
            .fill(Color(white: 0.16))
            .frame(width: box.width, height: box.height)
    }

    private func placement(smear: Bool) -> FlightPlacement {
        FlightPlacement(
            travel: model.travel,
            trail: model.trail,
            air: model.air,
            start: CGPoint(x: model.start.midX, y: model.start.midY),
            finish: CGPoint(x: model.finish.midX, y: model.finish.midY),
            smear: smear
        )
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
