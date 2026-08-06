import CoreGraphics
import Foundation

/// Шкала индикатора громкости: из RMS звука в долю высоты столбика.
///
/// Вынесена из вьюхи ради теста — именно эта шкала однажды «съела» тихую речь. Линейная
/// громкость для речи не годится: разговор с метра от ноутбука — это сотые доли единицы,
/// и на линейной шкале столбики почти не шевелятся, хотя микрофон слышит нормально.
/// Поэтому переводим в децибелы и растягиваем рабочий диапазон речи на всю высоту.
enum MeterScale {
    /// Тихий голос издалека.
    static let quietest: Float = -55
    /// Разговор в упор. Выше — только крик, полку держим здесь.
    static let loudest: Float = -12

    static func height(of level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(level)
        let share = (decibels - quietest) / (loudest - quietest)
        return CGFloat(min(1, max(0, share)))
    }
}
