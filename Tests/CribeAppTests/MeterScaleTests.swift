import XCTest
@testable import Cribe

/// Шкала индикатора громкости. Тесты существуют из-за двух живых жалоб подряд: сперва
/// «говорю за метр, а волны почти не двигаются», потом «в тишине столбики стоят высоко».
/// Обе — про одно и то же: фиксированная шкала не совпадает с настоящим микрофоном.
final class MeterScaleTests: XCTestCase {
    /// Настоящие уровни из записей владельца, в линейном RMS: тишина, обычная речь, пик.
    private let quiet = pow(10, Float(-38) / 20)
    private let speech = pow(10, Float(-33) / 20)
    private let peak = pow(10, Float(-25) / 20)

    /// Тишина — ноль, отрицательных значений не бывает.
    func testSilenceIsFlat() {
        let range = MeterRange()
        XCTAssertEqual(range.height(of: 0), 0)
        XCTAssertEqual(range.height(of: -1), 0)
    }

    /// Комната шумит ровно — ряд стоит внизу. Именно на это и была жалоба: тишина
    /// показывалась заметной высотой, потому что шкала ждала более тихого мира.
    func testSteadyRoomNoiseStaysAtTheBottom() {
        var range = MeterRange()
        for _ in 0..<MeterRange.capacity { range.push(quiet) }
        XCTAssertLessThan(range.height(of: quiet), 0.05)
    }

    /// Тот же микрофон, но человек заговорил: речь обязана подняться высоко, а не остаться
    /// в нижней трети. Размах у этой записи всего тринадцать децибел.
    func testSpeechRisesOnTheSameMicrophone() {
        var range = MeterRange()
        for _ in 0..<40 { range.push(quiet) }
        for _ in 0..<20 { range.push(peak) }

        XCTAssertLessThan(range.height(of: quiet), 0.15, "тишина остаётся внизу")
        XCTAssertGreaterThan(range.height(of: speech), 0.25, "обычная речь заметна")
        XCTAssertGreaterThan(range.height(of: peak), 0.8, "пик почти достаёт верх")
    }

    /// Микрофон вдвое громче — картинка та же. В этом весь смысл самонастройки: у другого
    /// человека уровни другие, а индикатор обязан выглядеть одинаково.
    func testLoudMicrophoneLooksTheSame() {
        var loud = MeterRange()
        let shift: Float = 4 // +12 dB
        for _ in 0..<40 { loud.push(quiet * shift) }
        for _ in 0..<20 { loud.push(peak * shift) }

        XCTAssertLessThan(loud.height(of: quiet * shift), 0.15)
        XCTAssertGreaterThan(loud.height(of: peak * shift), 0.8)
    }

    /// Громче — выше, без исключений.
    func testLouderIsAlwaysHigher() {
        var range = MeterRange()
        for _ in 0..<30 { range.push(quiet) }
        for _ in 0..<30 { range.push(peak) }

        let levels: [Float] = [quiet, speech, peak, 1]
        let heights = levels.map { range.height(of: $0) }
        XCTAssertEqual(heights, heights.sorted(), "шкала обязана быть монотонной")
    }

    /// Верх шкалы не улетает выше единицы даже на кличе в упор.
    func testLoudestStaysWithinBounds() {
        var range = MeterRange()
        for _ in 0..<MeterRange.capacity { range.push(speech) }
        XCTAssertLessThanOrEqual(range.height(of: 1), 1)
    }
}
