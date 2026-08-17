import XCTest
@testable import CribeCore

final class ShortDictationTests: XCTestCase {
    private func skips(
        _ text: String,
        enabled: Bool = true,
        limit: Int = 8,
        translating: Bool = false,
        engine: RecognitionEngine = .fast
    ) -> Bool {
        ShortDictation.skipsGPT(
            text: text, enabled: enabled, wordLimit: limit, translating: translating, engine: engine
        )
    }

    func testShortTextSkipsGPT() {
        XCTAssertTrue(skips("да, давай"))
        XCTAssertTrue(skips("ок"))
    }

    /// Граница включающая: ровно лимит — ещё короткая диктовка.
    func testLimitIsInclusive() {
        XCTAssertTrue(skips("раз два три четыре пять шесть семь восемь"))
        XCTAssertFalse(skips("раз два три четыре пять шесть семь восемь девять"))
    }

    /// Слова считаются по любым пробельным символам, включая переводы строк и повторные пробелы.
    func testWordCountIgnoresExtraWhitespace() {
        XCTAssertEqual(ShortDictation.wordCount("  раз\n\nдва   три  "), 3)
        XCTAssertEqual(ShortDictation.wordCount("   "), 0)
    }

    /// Перевод делает тот же вызов GPT — с ним слой 3 обязателен даже на одном слове.
    func testTranslationKeepsGPT() {
        XCTAssertFalse(skips("привет", translating: true))
    }

    func testDisabledGateKeepsGPT() {
        XCTAssertFalse(skips("привет", enabled: false))
    }

    /// Parakeet держится на чистке — она возвращает латиницу названиям, которые он записал
    /// кириллицей. Пропускать её нельзя даже на одном слове: «дэплой» — ровно тот случай.
    func testParakeetKeepsGPTOnShortDictation() {
        XCTAssertFalse(skips("дэплой", engine: .parakeet))
        XCTAssertTrue(skips("дэплой", engine: .fast))
        XCTAssertTrue(skips("дэплой", engine: .precise))
    }

    /// Выключенный гейт остаётся выключенным: у Parakeet требование к чистке своё, а не
    /// поверх чужого выбора.
    func testParakeetDoesNotRevivePassthroughForLongText() {
        let long = "раз два три четыре пять шесть семь восемь девять"
        XCTAssertFalse(skips(long, engine: .parakeet))
        XCTAssertFalse(skips(long, engine: .fast))
    }

    func testAlwaysCleansOnlyForParakeet() {
        XCTAssertTrue(RecognitionEngine.parakeet.alwaysCleans)
        XCTAssertFalse(RecognitionEngine.fast.alwaysCleans)
        XCTAssertFalse(RecognitionEngine.precise.alwaysCleans)
    }
}
