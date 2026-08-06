import SwiftUI

/// Тело перелёта: скруглённый прямоугольник и больше ничего.
///
/// Одна фигура на всю дорогу — капсула (190×44, радиус в половину высоты) и карточка
/// (300×высота, радиус 14) отличаются ТОЛЬКО тремя числами, и все три анимируемые: поэтому
/// промежуточные кадры считает сама SwiftUI, а силуэт ни на одном из них не подменяется.
///
/// Ни хвоста, ни шейки, ни острия: «капля» здесь — это движение, а не форма. Жидкость
/// читается растяжением по ходу, отставанием задней кромки и тем, как ширина растекается
/// в рамку карточки последней (см. `CardFlight`).
struct FlightCapsule: Shape {
    /// Габарит тела.
    var width: CGFloat
    var height: CGFloat
    /// Скругление; больше половины высоты не бывает — это уже капсула.
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(width, AnimatablePair(height, corner)) }
        set {
            width = newValue.first
            height = newValue.second.first
            corner = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: max(1, width),
            height: max(1, height)
        )
        return Path(
            roundedRect: body,
            cornerRadius: min(max(0, corner), body.height / 2),
            style: .continuous
        )
    }
}
