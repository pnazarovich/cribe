import XCTest
@testable import Cribe

/// Шкала индикатора громкости. Тесты существуют из-за трёх живых жалоб подряд: «говорю за
/// метр, а волны почти не двигаются», «в тишине столбики стоят высоко» и «на улице она
/// постоянно скачет». Все три — про одно: шкала обязана подстраиваться под настоящий
/// микрофон, но делать это медленно.
final class MeterScaleTests: XCTestCase {
    /// Настоящие уровни из записей владельца, в линейном RMS: тишина, обычная речь, пик.
    ///
    /// Перцентили по 238 кадрам трёх записей целиком: 5% — −44 dBFS, 80% — −28, 99% — −20.
    /// Прежний набор был снят иначе и брал за тишину медиану (−38) — то есть паузы между
    /// словами, а не шум комнаты. Из-за этого весь размах выглядел как тринадцать децибел
    /// вместо настоящих двадцати с лишним, шкалу подгоняли под него, и обычная речь
    /// упиралась в потолок: жалоба «всё на максимуме» была именно про это.
    private let quiet = pow(10, Float(-43) / 20)
    private let speech = pow(10, Float(-30) / 20)
    private let peak = pow(10, Float(-21) / 20)

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

    /// Настоящее начало записи, снятое с живого приложения (журнал, шаг кадра 10 мс).
    /// Микрофон просыпается: уровень падает с −48 dBFS до −147, то есть в цифровую тишину,
    /// и только к двумстам миллисекундам поднимается к настоящему шуму комнаты.
    ///
    /// Это и есть та самая жалоба «при включении всё на максимуме». Калибровка бралась
    /// прямо со склона, пол шкалы догонял падение и укладывался на −122 дБ, размах
    /// становился семьдесят децибел — и всё настоящее оказывалось у верхнего края.
    private let liveOnset: [(time: TimeInterval, decibels: Float)] = [
        (0.000, -48.6), (0.011, -58.8), (0.028, -66.5), (0.033, -72.3), (0.050, -80.7),
        (0.068, -102.4), (0.074, -109.9), (0.083, -116.6), (0.095, -125.4), (0.106, -136.3),
        (0.115, -147.0), (0.127, -133.1), (0.137, -97.0), (0.148, -75.1), (0.158, -50.5),
        (0.175, -45.3), (0.181, -43.2), (0.189, -44.9), (0.200, -42.6), (0.221, -40.0),
    ]

    /// Пока микрофон просыпается, ряд стоит на нуле — показывать нечего.
    func testWakingMicrophoneShowsNothing() {
        var range = MeterRange()
        for frame in liveOnset {
            XCTAssertEqual(
                range.push(pow(10, frame.decibels / 20), at: frame.time), 0,
                "кадр \(frame.time) с: микрофон ещё просыпается"
            )
        }
    }

    /// И, что важнее, просыпание не портит шкалу на потом: после него обычная речь
    /// обязана оказаться в середине, а не упереться в потолок.
    func testWakingMicrophoneDoesNotBreakTheScaleAfterwards() {
        var range = MeterRange()
        for frame in liveOnset { _ = range.push(pow(10, frame.decibels / 20), at: frame.time) }

        // Проснувшийся микрофон отдаёт шум комнаты; на нём шкала и калибруется.
        var time = MeterRange.wakeUp
        for _ in 0..<20 {
            _ = range.push(quiet, at: time)
            time += 0.01
        }
        XCTAssertLessThan(settled(range, at: speech), 0.85, "речь не упирается в потолок")
        XCTAssertGreaterThan(settled(range, at: speech), 0.2, "и всё же заметна")
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
        // Жалоба «всё на максимуме» была ровно про это: верх шкалы обязан оставаться
        // запасом под пики, а не быть местом, где стоит обычная речь.
        XCTAssertLessThan(settled(range, at: speech), 0.85, "обычная речь не упирается в потолок")
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
