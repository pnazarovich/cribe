import CoreGraphics

/// Арифметика смахивания карточки: порог, бросок и сопротивление вправо.
/// Вынесена отдельно от жеста, потому что сам жест проверяется только пальцем,
/// а вот числа — тестом.
enum CardSwipe {
    /// Дальше этой доли ширины карточка уже не возвращается.
    static let dismissFraction: CGFloat = 0.35

    /// Бросок: короткое резкое движение убирает карточку, не доводя её до порога.
    /// Единица — точки за одно событие трекпада (их приходит около 60 в секунду).
    static let flingSpeed: CGFloat = 9

    /// Насколько карточка гаснет к порогу: на самом пороге остаётся 0.45 непрозрачности —
    /// уже понятно, что она уходит, но ещё видно, что именно уходит.
    static let fadeAtThreshold: CGFloat = 0.55

    /// Смещение карточки за пальцами.
    ///
    /// Влево карточка идёт след в след, вправо — с резиновым сопротивлением: уводить её
    /// вправо некуда (стопка живёт у левого края), но мёртвый край читался бы как поломка.
    /// Формула та же, что у резинового края списков: чем дальше, тем меньше отдача.
    static func offset(forFingerTravel travel: CGFloat, width: CGFloat) -> CGFloat {
        guard travel > 0 else { return travel }
        let limit = width * 0.55
        return (1 - 1 / (travel / limit + 1)) * limit
    }

    /// Уходит ли карточка: либо утащили за порог, либо бросили влево на скорости.
    static func dismisses(offset: CGFloat, speed: CGFloat, width: CGFloat) -> Bool {
        offset <= -width * dismissFraction || speed <= -flingSpeed
    }

    /// Прозрачность карточки на текущем сдвиге: гаснет только уход влево.
    static func opacity(offset: CGFloat, width: CGFloat) -> Double {
        guard offset < 0 else { return 1 }
        let progress = min(1, -offset / (width * dismissFraction))
        return 1 - Double(progress) * (1 - Double(fadeAtThreshold))
    }
}
