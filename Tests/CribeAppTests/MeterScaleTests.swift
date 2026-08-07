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

    /// Устоявшаяся высота: несколько замеров одного уровня подряд, как в жизни.
    private func settled(_ range: MeterRange, at level: Float) -> CGFloat {
        var probe = range
        var height: CGFloat = 0
        for _ in 0..<20 { height = probe.push(level) }
        return height
    }

    /// Тишина — ноль, отрицательных значений не бывает.
    func testSilenceIsFlat() {
        var range = MeterRange()
        XCTAssertEqual(range.push(0), 0)
        XCTAssertEqual(range.push(-1), 0)
    }

    /// Самые первые кадры после появления индикатора. Шкала ещё ничего не знает о комнате,
    /// и раньше начинала с фиксированных границ: шум попадал в середину шкалы, и ряд
    /// вспыхивал на максимум — «всё на максимуме, как будто очень шумно».
    func testFirstFramesDoNotFlashToTheTop() {
        var range = MeterRange()
        for _ in 0..<6 {
            XCTAssertLessThan(range.push(quiet), 0.2, "индикатор не имеет права стартовать с максимума")
        }
    }

    /// Щелчок в первом буфере — обычное дело на старте записи. Калибровка обязана взять
    /// самый тихий из первых кадров, иначе шкала съезжает и весь ряд вспыхивает.
    func testStartupClickDoesNotSkewTheScale() {
        var range = MeterRange()
        _ = range.push(peak)      // щелчок
        _ = range.push(quiet)
        _ = range.push(quiet)

        for _ in 0..<3 {
            XCTAssertLessThan(range.push(quiet), 0.2, "щелчок старта не должен задирать шкалу")
        }
    }

    /// Настоящее начало записи, снятое с трёх записей владельца: первый кадр около −50 dBFS,
    /// второй — **пустой буфер** (−98…−115), и только с третьего идёт шум комнаты. Калибровка
    /// по минимуму ловила именно пустой буфер: пол уезжал на −117, шум комнаты оказывался
    /// выше потолка, и ряд вспыхивал на максимум — жалоба «всё на максимуме, а в комнате тихо».
    func testRealStartOfRecordingDoesNotFlash() {
        var range = MeterRange()
        let onset: [Float] = [-52, -115, -41, -36, -39, -42, -39, -41, -41, -38, -40, -39]
        var highest: CGFloat = 0
        for decibels in onset { highest = max(highest, range.push(pow(10, decibels / 20))) }
        XCTAssertLessThan(highest, 0.35, "начало записи не имеет права вспыхивать на максимум")
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

        // Высота сглажена по нескольким замерам, поэтому и проверяем её устоявшейся:
        // одиночный замер по построению доезжает лишь до пятой части цели.
        XCTAssertGreaterThan(settled(range, at: speech), 0.25, "обычная речь заметна")
        XCTAssertGreaterThan(settled(range, at: peak), 0.6, "пик уходит вверх")
    }

    /// Микрофон вдвое громче — картинка та же. В этом весь смысл самонастройки.
    func testLoudMicrophoneLooksTheSame() {
        var loud = MeterRange()
        let shift: Float = 4 // +12 dB
        for _ in 0..<200 { _ = loud.push(quiet * shift) }

        XCTAssertGreaterThan(settled(loud, at: peak * shift), 0.6)
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

        let heights = [quiet, speech, peak].map { settled(range, at: $0) }
        XCTAssertEqual(heights, heights.sorted(), "шкала обязана быть монотонной")
    }

    /// Верх шкалы не улетает выше единицы даже на крике в упор.
    func testLoudestStaysWithinBounds() {
        var range = MeterRange()
        for _ in 0..<200 { _ = range.push(speech) }
        XCTAssertLessThanOrEqual(settled(range, at: 1), 1)
    }
}
