import XCTest
@testable import Cribe

/// Шкала индикатора громкости. Тесты существуют из-за трёх живых жалоб подряд: «говорю за
/// метр, а волны почти не двигаются», «в тишине столбики стоят высоко» и «на улице она
/// постоянно скачет». Все три — про одно: шкала обязана подстраиваться под настоящий
/// микрофон, но делать это медленно.
final class MeterScaleTests: XCTestCase {
    /// Настоящие уровни из записей владельца, в линейном RMS: тишина, обычная речь, пик.
    private let quiet = pow(10, Float(-38) / 20)
    private let speech = pow(10, Float(-33) / 20)
    private let peak = pow(10, Float(-25) / 20)

    /// Тишина — ноль, отрицательных значений не бывает.
    func testSilenceIsFlat() {
        var range = MeterRange()
        XCTAssertEqual(range.push(0), 0)
        XCTAssertEqual(range.push(-1), 0)
    }

    /// Комната шумит ровно — ряд стоит внизу. Первая жалоба была именно на это.
    func testSteadyRoomNoiseSettlesAtTheBottom() {
        var range = MeterRange()
        var height: CGFloat = 1
        for _ in 0..<200 { height = range.push(quiet) }
        XCTAssertLessThan(height, 0.1, "ровный шум обязан осесть в самый низ")
    }

    /// Тот же микрофон, но человек заговорил: речь поднимается высоко, хотя весь размах
    /// этой записи — тринадцать децибел.
    func testSpeechRisesOnTheSameMicrophone() {
        var range = MeterRange()
        for _ in 0..<200 { _ = range.push(quiet) }

        XCTAssertGreaterThan(range.push(speech), 0.25, "обычная речь заметна")
        XCTAssertGreaterThan(range.push(peak), 0.6, "пик уходит вверх")
    }

    /// Микрофон вдвое громче — картинка та же. В этом весь смысл самонастройки.
    func testLoudMicrophoneLooksTheSame() {
        var loud = MeterRange()
        let shift: Float = 4 // +12 dB
        for _ in 0..<200 { _ = loud.push(quiet * shift) }

        XCTAssertGreaterThan(loud.push(peak * shift), 0.6)
    }

    /// Улица: шум гуляет туда-сюда. Границы обязаны ползти, а не бегать за каждым всплеском,
    /// иначе ряд пляшет — ровно та жалоба, из-за которой шкалу переписали второй раз.
    func testNoisyStreetDoesNotSwingTheScale() {
        var range = MeterRange()
        for _ in 0..<200 { _ = range.push(quiet) }
        let settled = range.floor

        // Секунда громкого шума мимо: 12 замеров при частоте обновления около 12 Гц.
        for _ in 0..<12 { _ = range.push(peak) }

        XCTAssertLessThan(abs(range.floor - settled), 3, "пол не имеет права прыгнуть за секунду")
    }

    /// Громче — выше, без исключений.
    func testLouderIsAlwaysHigher() {
        var range = MeterRange()
        for _ in 0..<200 { _ = range.push(quiet) }

        let heights = [quiet, speech, peak].map { level -> CGFloat in
            var probe = range
            return probe.push(level)
        }
        XCTAssertEqual(heights, heights.sorted(), "шкала обязана быть монотонной")
    }

    /// Верх шкалы не улетает выше единицы даже на крике в упор.
    func testLoudestStaysWithinBounds() {
        var range = MeterRange()
        for _ in 0..<200 { _ = range.push(speech) }
        XCTAssertLessThanOrEqual(range.push(1), 1)
    }
}
