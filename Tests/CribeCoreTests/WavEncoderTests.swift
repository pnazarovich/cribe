import XCTest
@testable import CribeCore

final class WavEncoderTests: XCTestCase {

    func testHeaderDescribes16BitMono16kHz() {
        let data = WavEncoder.encode([0, 0, 0, 0])

        XCTAssertEqual(data.count, 44 + 8)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        XCTAssertEqual(le32(data, 4), UInt32(36 + 8))   // размер RIFF
        XCTAssertEqual(le16(data, 20), 1)               // PCM
        XCTAssertEqual(le16(data, 22), 1)               // моно
        XCTAssertEqual(le32(data, 24), 16_000)          // частота
        XCTAssertEqual(le32(data, 28), 32_000)          // байт в секунду
        XCTAssertEqual(le16(data, 32), 2)               // выравнивание блока
        XCTAssertEqual(le16(data, 34), 16)              // бит на сэмпл
        XCTAssertEqual(le32(data, 40), 8)               // размер данных
    }

    func testSamplesAreScaledAndClamped() {
        let data = WavEncoder.encode([0, 1, -1, 2, -2])

        XCTAssertEqual(Int16(bitPattern: le16(data, 44)), 0)
        XCTAssertEqual(Int16(bitPattern: le16(data, 46)), 32_767)
        XCTAssertEqual(Int16(bitPattern: le16(data, 48)), -32_767)
        XCTAssertEqual(Int16(bitPattern: le16(data, 50)), 32_767)
        XCTAssertEqual(Int16(bitPattern: le16(data, 52)), -32_767)
    }

    // MARK: - Чаймы SoundPlayer (проверить на слух агент не может — проверяем данные)

    func testChimesAreValidWavWithExpectedDuration() {
        for (name, data) in chimes {
            XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF", name)
            XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE", name)
            XCTAssertEqual(le32(data, 4), UInt32(data.count - 8), name)     // размер RIFF
            XCTAssertEqual(le16(data, 20), 1, name)                         // PCM
            XCTAssertEqual(le16(data, 22), 1, name)                         // моно
            XCTAssertEqual(le32(data, 24), 44_100, name)                    // частота
            XCTAssertEqual(le16(data, 34), 16, name)                        // бит на сэмпл

            let dataSize = Int(le32(data, 40))
            XCTAssertEqual(dataSize, data.count - 44, name)
            let duration = Double(dataSize) / 2 / 44_100
            // Границы широкие намеренно: точная длина — дело вкуса и менялась вместе с
            // выбранным звуком. Проверяем только то, что и правда важно: чайм успевает
            // прозвучать и не превращается в мелодию поверх начатой речи.
            XCTAssertGreaterThan(duration, 0.15, "чайм \(name) слишком короткий: \(duration) с")
            XCTAssertLessThan(duration, 0.40, "чайм \(name) слишком длинный: \(duration) с")
        }
    }

    /// Пик нормирован в 0.5: слышно, но с запасом до клиппинга.
    func testChimesPeakAtHalfScale() {
        for (name, data) in chimes {
            let peak = samples(data).map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.45, "чайм \(name) слишком тихий: пик \(peak)")
            XCTAssertLessThan(peak, 0.55, "чайм \(name) слишком громкий: пик \(peak)")
        }
    }

    /// Щелчок в звуке — это разрыв сигнала. Ищем его как скачок между соседними
    /// сэмплами: на плавных огибающих шаг не превышает сотых долей шкалы.
    func testChimesHaveNoClicks() {
        for (name, data) in chimes {
            let wave = samples(data)
            let jump = zip(wave, wave.dropFirst()).map { abs($1 - $0) }.max() ?? 0
            XCTAssertLessThan(jump, 0.12, "чайм \(name) щёлкает: скачок \(jump)")
        }
    }

    /// Края файла — тишина: устройство не получает ни рывка на старте, ни обрыва хвоста.
    func testChimeEdgesAreSilent() {
        let edge = 44_100 / 200   // 5 мс
        for (name, data) in chimes {
            let wave = samples(data)
            let head = wave.prefix(edge).map { abs($0) }.max() ?? 0
            let tail = wave.suffix(edge).map { abs($0) }.max() ?? 0
            XCTAssertLessThan(head, 0.01, "чайм \(name) начинается рывком: \(head)")
            XCTAssertLessThan(tail, 0.01, "чайм \(name) обрывается: \(tail)")
        }
    }

    /// Готовые WAV можно послушать: путь задаётся снаружи, в обычном прогоне тест молчит.
    func testDumpChimesWhenRequested() throws {
        guard let dir = ProcessInfo.processInfo.environment["CHIME_WAV_DIR"] else { return }
        for (name, data) in [("start", SoundPlayer.startWav), ("stop", SoundPlayer.stopWav)] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chime-\(name).wav"))
        }
    }

    private var chimes: [(String, Data)] {
        [("старт", SoundPlayer.startWav), ("стоп", SoundPlayer.stopWav)]
    }

    private func samples(_ data: Data) -> [Float] {
        stride(from: 44, to: data.count, by: 2)
            .map { Float(Int16(bitPattern: le16(data, $0))) / 32_767 }
    }

    private func le16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * UInt32($1)) }
    }
}
