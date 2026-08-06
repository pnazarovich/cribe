import XCTest
@testable import CribeCore

final class ShortDictationTests: XCTestCase {
    private func skips(_ text: String, enabled: Bool = true, limit: Int = 8, translating: Bool = false) -> Bool {
        ShortDictation.skipsGPT(text: text, enabled: enabled, wordLimit: limit, translating: translating)
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
}
