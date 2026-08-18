import XCTest
@testable import CribeCore

/// От гейта коротких диктовок (`skipsGPT`) не осталось ни поведения, ни настройки: с
/// единственным Parakeet латиницу английским названиям возвращает только чистка, и на
/// однословном «дэплой» её пропуск был виден ярче всего. Проверки про пропуск GPT ушли
/// вместе с ним — из `ShortDictation` уцелел один подсчёт слов.
final class ShortDictationTests: XCTestCase {

    /// Слова считаются по любым пробельным символам, включая переводы строк и повторные пробелы.
    func testWordCountIgnoresExtraWhitespace() {
        XCTAssertEqual(ShortDictation.wordCount("  раз\n\nдва   три  "), 3)
        XCTAssertEqual(ShortDictation.wordCount("   "), 0)
    }
}
