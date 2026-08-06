import XCTest
@testable import CribeCore

/// Молчаливая потеря речи — худший из отказов: человек говорил минуту, а на выходе строчка,
/// и понять это можно было только по памяти. Проверка грубая и намеренно осторожная:
/// ложная тревога после каждой диктовки хуже, чем пропущенный редкий случай.
final class TranscriptQualityTests: XCTestCase {

    func testLongRecordingWithAlmostNoTextIsSuspicious() {
        XCTAssertTrue(TranscriptQuality.looksTruncated(words: 12, seconds: 90))
        XCTAssertTrue(TranscriptQuality.looksTruncated(words: 0, seconds: 30))
    }

    /// Обычная диктовка тревоги не поднимает: даже медленная речь с паузами даёт
    /// куда больше слов в секунду, чем порог.
    func testNormalDictationIsFine() {
        XCTAssertFalse(TranscriptQuality.looksTruncated(words: 150, seconds: 90))
        XCTAssertFalse(TranscriptQuality.looksTruncated(words: 40, seconds: 60))
    }

    /// Короткую диктовку не судим вовсе: «ок» за пять секунд — это не потеря речи,
    /// а самый частый способ пользоваться приложением.
    func testShortDictationIsNeverSuspicious() {
        XCTAssertFalse(TranscriptQuality.looksTruncated(words: 1, seconds: 5))
        XCTAssertFalse(TranscriptQuality.looksTruncated(words: 0, seconds: 19))
    }

    /// Длительности нет (запись не сохранилась) — судить не по чему.
    func testUnknownDurationIsNotJudged() {
        XCTAssertFalse(TranscriptQuality.looksTruncated(words: 0, seconds: nil))
    }
}
