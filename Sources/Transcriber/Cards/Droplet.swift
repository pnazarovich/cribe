import SwiftUI

/// Форма, которой живёт весь перелёт: скруглённый прямоугольник с необязательным хвостом.
///
/// Одна семья форм на три состояния — и потому переход идёт одним движением, без подмены
/// вида: капсула (190×44, радиус в половину высоты, хвоста нет) → капля (голова 54×54,
/// хвост вправо, шейка перехвачена) → карточка (300×высота, радиус 14, хвоста снова нет).
/// Всё это анимируемые числа, поэтому промежуточные кадры считает сама SwiftUI.
///
/// Хвост подрисовывается вторым подконтуром внахлёст с телом: при ненулевой намотке
/// (`.nonZero`, она по умолчанию) два пересекающихся контура заливаются как объединение,
/// поэтому шва на стыке нет.
struct Droplet: Shape {
    /// Габарит тела.
    var width: CGFloat
    var height: CGFloat
    /// Скругление тела; больше половины высоты не бывает — это уже капсула.
    var corner: CGFloat
    /// Длина хвоста вправо от правого края тела. 0 — хвоста нет.
    var tail: CGFloat
    /// Доля высоты, до которой сужается тело у основания хвоста: 1 — не сужено.
    var neck: CGFloat

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>
    > {
        get {
            AnimatablePair(
                AnimatablePair(width, height),
                AnimatablePair(corner, AnimatablePair(tail, neck))
            )
        }
        set {
            width = newValue.first.first
            height = newValue.first.second
            corner = newValue.second.first
            tail = newValue.second.second.first
            neck = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: max(1, width),
            height: max(1, height)
        )
        var path = Path(
            roundedRect: body,
            cornerRadius: min(corner, body.height / 2),
            style: .continuous
        )
        guard tail > 0.5 else { return path }

        // Хвост: от правой кромки тела двумя квадратичными кривыми в остриё. Начало
        // заводится ВНУТРЬ тела (на радиус скругления), чтобы стык растворился в заливке.
        let start = body.maxX - min(corner, body.height / 2)
        let waist = max(0.5, body.height / 2 * neck)
        let tip = CGPoint(x: body.maxX + tail, y: body.midY)
        path.move(to: CGPoint(x: start, y: body.midY - waist))
        path.addQuadCurve(to: tip, control: CGPoint(x: body.maxX + tail * 0.35, y: body.midY - waist * 0.75))
        path.addQuadCurve(
            to: CGPoint(x: start, y: body.midY + waist),
            control: CGPoint(x: body.maxX + tail * 0.35, y: body.midY + waist * 0.75)
        )
        path.closeSubpath()
        return path
    }
}
