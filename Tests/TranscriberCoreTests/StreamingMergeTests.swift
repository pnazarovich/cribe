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

    /// Повтор одного слова — худший случай для поиска стыка: «настоящим» выглядит любая длина.
    /// Потолок в 4 слова (в нахлёст 0.5 c больше и не влезает) ограничивает потерю: из 10 + 10
    /// слов остаётся 16, а не 10, как было бы с потолком в 12.
    func testRepeatedWordsCollapseNoFurtherThanTheCap() {
        let run = Array(repeating: "да", count: 10).joined(separator: " ")

        let merged = StreamingMerge.merge(confirmed: run, tail: run)

        XCTAssertEqual(ShortDictation.wordCount(merged), 16)
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

    /// Проход без текста не подтверждает ничего. Иначе он поднял бы границу подтверждённого,
    /// а она монотонна — следующий, уже осмысленный проход не смог бы её сдвинуть, и потоковый
    /// путь молча умер бы на всю сессию.
    func testConfirmedIgnoresPassWithoutText() {
        XCTAssertNil(StreamingMerge.confirmed(from: [
            ASRSegment(text: "", start: 0, end: 3),
            ASRSegment(text: "", start: 3, end: 6),
        ]))
    }

    /// Хвостовые пустые сегменты границу не двигают: она встаёт по последнему сегменту с текстом.
    func testConfirmedDropsTrailingEmptySegments() {
        let pass = StreamingMerge.confirmed(from: [
            ASRSegment(text: "раз два", start: 0, end: 2),
            ASRSegment(text: "", start: 2, end: 5),
            ASRSegment(text: "три", start: 5, end: 7),
        ])

        XCTAssertEqual(pass?.text, "раз два")
        XCTAssertEqual(pass?.endSample, 2 * 16_000)
    }

    /// Битый таймкод из модели не должен дойти до `Int(_:)` — на NaN и бесконечности он падает.
    func testConfirmedRejectsBrokenTimestamp() {
        XCTAssertNil(StreamingMerge.confirmed(from: [
            ASRSegment(text: "раз", start: 0, end: .nan),
            ASRSegment(text: "два", start: 1, end: 2),
        ]))
        XCTAssertNil(StreamingMerge.confirmed(from: [
            ASRSegment(text: "раз", start: 0, end: .infinity),
            ASRSegment(text: "два", start: 1, end: 2),
        ]))
    }
}
