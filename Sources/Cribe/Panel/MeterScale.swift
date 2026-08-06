import CoreGraphics
import Foundation

/// Шкала индикатора громкости: из RMS звука в долю высоты столбика.
///
/// Шкала **самонастраивающаяся**, и это не украшательство, а единственный работающий путь.
/// Фиксированные пороги в децибелах не годятся: у каждого микрофона своя чувствительность,
/// у каждой комнаты свой шум, а системная громкость входа — вообще ползунок, который человек
/// двигает как хочет. Замер на настоящих записях владельца: тишина −38 dBFS, речь −33, пики
/// −25, то есть весь размах тринадцать децибел. На фиксированной шкале −55…−12 такая тишина
/// приходилась на четверть высоты — столбики «стояли высоко», хотя никто не говорил.
///
/// Поэтому вместо порогов — окно недавних уровней: нижняя граница берётся по тихим кадрам,
/// верхняя по громким, и высота считается уже относительно них. Тишина всегда оказывается
/// внизу, речь — вверху, и мышке пользователя не нужно ничего настраивать.
enum MeterScale {
    /// Наименьший размах шкалы. Без него в полной тишине разница между «чуть тише» и «чуть
    /// громче» растянулась бы на всю высоту и ряд бы плясал от шороха.
    static let minimumSpan: Float = 12

    /// Доля высоты для уровня `level` при известных границах окна (в децибелах).
    static func height(of level: Float, floor: Float, ceiling: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(level)
        let span = max(minimumSpan, ceiling - floor)
        return CGFloat(min(1, max(0, (decibels - floor) / span)))
    }
}

/// Окно недавних уровней, по которому шкала находит свои границы.
///
/// Границы — не минимум и максимум, а перцентили: одиночный щелчок по столу не должен
/// переопределять верх шкалы на пять секунд, а один особо тихий кадр — низ.
struct MeterRange {
    /// Пять секунд при частоте обновления уровня около 12 Гц.
    static let capacity = 60

    private var decibels: [Float] = []

    /// Нижняя граница: тихие кадры окна. Если человек говорит без пауз, ею становится
    /// самый тихий слог — это правильно, шкала подстраивается под живую речь.
    private(set) var floor: Float = -60
    /// Верхняя граница: громкие кадры, но не единичный выброс.
    private(set) var ceiling: Float = -20

    mutating func push(_ level: Float) {
        guard level > 0 else { return }
        decibels.append(20 * log10(level))
        if decibels.count > Self.capacity {
            decibels.removeFirst(decibels.count - Self.capacity)
        }
        let sorted = decibels.sorted()
        floor = sorted[sorted.count / 5]
        ceiling = sorted[min(sorted.count - 1, sorted.count * 19 / 20)]
    }

    func height(of level: Float) -> CGFloat {
        MeterScale.height(of: level, floor: floor, ceiling: ceiling)
    }
}
