import XCTest
@testable import CribeCore

final class AudioNormalizerTests: XCTestCase {

    /// Тихая запись поднимается до целевого пика: ради этого нормализация и заведена.
    func testQuietRecordingReachesTargetPeak() {
        let quiet = AudioNormalizerTests.tone(peak: 0.05)

        let loud = AudioNormalizer.normalized(quiet)

        XCTAssertEqual(AudioNormalizer.peak(loud), AudioNormalizer.targetPeak, accuracy: 0.01)
    }

    /// Запись, которая и так на уровне, не трогаем: усиление ниже порога смысла не имеет.
    func testLoudRecordingIsLeftAlone() {
        let loud = AudioNormalizerTests.tone(peak: 0.8)

        XCTAssertEqual(AudioNormalizer.gain(forPeak: 0.8), 1)
        XCTAssertEqual(AudioNormalizer.normalized(loud), loud)
    }

    /// Потолок усиления обязателен: без него шум в паузах раскачался бы до уровня речи,
    /// и ворота речи начали бы срабатывать на пустоте.
    func testGainIsCapped() {
        XCTAssertEqual(AudioNormalizer.gain(forPeak: 0.001), AudioNormalizer.maxGain)
        XCTAssertLessThanOrEqual(AudioNormalizer.gain(forPeak: 0.0004), AudioNormalizer.maxGain)
    }

    /// Мёртвый вход (пик ниже −70 dBFS) не усиливаем вовсе: там не тихая речь, а цифровая
    /// тишина, и поднимать её до уровня речи — значит выдать шум за диктовку. Порог общий
    /// с `CaptureRecorder`, второго в приложении нет.
    func testDigitalSilenceIsNotAmplified() {
        XCTAssertEqual(AudioNormalizer.gain(forPeak: 0.0001), 1)
        XCTAssertEqual(AudioNormalizer.gain(forPeak: 0), 1)

        let silence = AudioNormalizerTests.tone(peak: 0.0001)
        XCTAssertEqual(AudioNormalizer.normalized(silence), silence)
    }

    /// Порог тишины — ровно тот, по которому захват судит о мёртвом микрофоне.
    func testSilenceThresholdIsTheSharedOne() {
        XCTAssertEqual(AudioNormalizer.gain(forPeak: AudioCaptureFormat.silenceThreshold * 0.99), 1)
        XCTAssertGreaterThan(AudioNormalizer.gain(forPeak: AudioCaptureFormat.silenceThreshold), 1)
    }

    /// Усиление одно на весь буфер: тихий кусок в середине не должен получить своё.
    func testGainIsSingleForWholeBuffer() {
        var samples = AudioNormalizerTests.tone(peak: 0.1)
        for index in samples.indices where index > samples.count / 2 {
            samples[index] /= 10
        }

        let loud = AudioNormalizer.normalized(samples)

        let factor = AudioNormalizer.gain(forPeak: 0.1)
        for (before, after) in zip(samples, loud) {
            XCTAssertEqual(after, before * factor, accuracy: 1e-5)
        }
    }

    func testEmptyBuffer() {
        XCTAssertEqual(AudioNormalizer.peak([]), 0)
        XCTAssertEqual(AudioNormalizer.normalized([]), [])
    }

    private static func tone(peak: Float) -> [Float] {
        (0..<1_000).map { peak * sin(Float($0) * 0.1) }
    }

    /// Готовый множитель и множитель «по себе» — одно и то же на одном буфере: `normalized`
    /// обязан остаться частным случаем `scaled`, иначе бегущая строка и финальный проход
    /// поехали бы разными путями.
    func testScaledIsTheGeneralCaseOfNormalized() {
        let quiet = (0..<1600).map { _ in Float.random(in: -0.05...0.05) }
        let byItself = AudioNormalizer.normalized(quiet)
        let byGain = AudioNormalizer.scaled(quiet, by: AudioNormalizer.gain(forPeak: AudioNormalizer.peak(quiet)))
        XCTAssertEqual(byItself, byGain)
    }

    /// Множитель ≤ 1 — буфер отдаётся как есть, без прохода по мегабайтам.
    func testScaledByOneReturnsTheBufferUntouched() {
        let samples: [Float] = [0.5, -0.5, 0.25]
        XCTAssertEqual(AudioNormalizer.scaled(samples, by: 1), samples)
        XCTAssertEqual(AudioNormalizer.scaled(samples, by: 0.3), samples)
    }

    /// Накопленный пик даёт не растущее усиление. Ради этого он и накапливается: иначе
    /// громкое слово, вошедшее в окно предпросмотра, роняло бы множитель, и одна и та же
    /// середина речи попадала бы в модель то тише, то громче — а модель на этом слышит
    /// её иначе, и строка переписывалась бы сама собой.
    func testAccumulatedPeakNeverRaisesTheGain() {
        var peak: Float = 0
        var gains: [Float] = []
        for windowPeak: Float in [0.02, 0.08, 0.4, 0.05, 0.2] {
            peak = max(peak, windowPeak)
            gains.append(AudioNormalizer.gain(forPeak: peak))
        }
        XCTAssertEqual(gains, gains.sorted(by: >), "усиление обязано только падать: \(gains)")
    }
}
