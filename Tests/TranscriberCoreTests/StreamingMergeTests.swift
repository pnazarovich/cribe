import XCTest
@testable import TranscriberCore

final class StreamingMergeTests: XCTestCase {

    /// Нахлёста не нашлось — слова терять нельзя, склеиваем всё подряд.
    func testNoOverlapConcatenates() {
        XCTAssertEqual(
            StreamingMerge.merge(confirmed: "раз два три", tail: "четыре пять"),
            "раз два три четыре пять"
        )
    }

    /// Хвост целиком повторяет конец подтверждённой части — дубля быть не должно.
    func testFullDuplicateCollapses() {
        XCTAssertEqual(
            StreamingMerge.merge(confirmed: "раз два три", tail: "два три"),
            "раз два три"
        )
        XCTAssertEqual(
            StreamingMerge.merge(confirmed: "раз два", tail: "раз два"),
            "раз два"
        )
    }

    /// Обычный случай: часть хвоста — нахлёст, часть — новые слова.
    func testPartialOverlap() {
        XCTAssertEqual(
            StreamingMerge.merge(confirmed: "а б в г", tail: "в г д е"),
            "а б в г д е"
        )
    }

    /// Регистр и пунктуация между проходами гуляют, стык всё равно должен схлопнуться,
    /// а в результат идут слова подтверждённой части — как есть.
    func testOverlapIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            StreamingMerge.merge(confirmed: "привет, мир", tail: "Мир! Как дела"),
            "привет, мир Как дела"
        )
    }

    /// Берём самый длинный стык: случайное совпадение одного слова не должно съесть
    /// настоящий нахлёст в три слова.
    func testLongestOverlapWins() {
        XCTAssertEqual(
            StreamingMerge.merge(confirmed: "и раз и два и три", tail: "и два и три и четыре"),
            "и раз и два и три и четыре"
        )
    }

    func testEmptySides() {
        XCTAssertEqual(StreamingMerge.merge(confirmed: "", tail: "раз два"), "раз два")
        XCTAssertEqual(StreamingMerge.merge(confirmed: "раз два", tail: ""), "раз два")
        XCTAssertEqual(StreamingMerge.merge(confirmed: "", tail: ""), "")
    }

    /// Лишние пробелы и переводы строк схлопываются: на выход идёт ровно по одному пробелу.
    func testWhitespaceIsNormalized() {
        XCTAssertEqual(
            StreamingMerge.merge(confirmed: "  раз\nдва  ", tail: " два   три "),
            "раз два три"
        )
    }

    // MARK: - Подтверждение прохода

    /// Последний сегмент нестабилен и в подтверждённую часть не попадает — ни текстом,
    /// ни таймкодом.
    func testConfirmedDropsLastSegment() {
        let pass = StreamingMerge.confirmed(from: [
            ASRSegment(text: "раз два", start: 0, end: 2),
            ASRSegment(text: "три четыре", start: 2, end: 5),
            ASRSegment(text: "пять", start: 5, end: 6),
        ])

        XCTAssertEqual(pass?.text, "раз два три четыре")
        XCTAssertEqual(pass?.endSample, 5 * 16_000)
    }

    /// Одного сегмента мало: подтверждать нечего, потоковый путь на таком проходе не включится.
    func testConfirmedNeedsTwoSegments() {
        XCTAssertNil(StreamingMerge.confirmed(from: []))
        XCTAssertNil(StreamingMerge.confirmed(from: [ASRSegment(text: "раз", start: 0, end: 1)]))
    }
}
