import XCTest
@testable import TranscriberCore

/// Промпт и расшифровка делят один бюджет токенов декодера, и длинный промпт молча съедает
/// хвост окна — см. комментарий у `WhisperEngine.maxPromptTokens`.
final class PromptBudgetTests: XCTestCase {

    /// Длинный промпт обрезается: иначе он забирает половину контекста окна, и на плотной
    /// речи текст обрывается посреди слова, а нерасшифрованный звук пропадает без ошибки.
    func testLongPromptIsCapped() {
        let tokens = Array(1...200)

        XCTAssertEqual(WhisperEngine.capped(tokens).count, WhisperEngine.maxPromptTokens)
    }

    /// Режем с начала: важные термины `PromptBuilder` держит ближе к хвосту промпта.
    func testCapKeepsTheTail() {
        let tokens = Array(1...200)

        XCTAssertEqual(WhisperEngine.capped(tokens).last, 200)
        XCTAssertEqual(WhisperEngine.capped(tokens).first, 200 - WhisperEngine.maxPromptTokens + 1)
    }

    /// Короткий промпт не трогаем вовсе.
    func testShortPromptIsUntouched() {
        let tokens = [7, 8, 9]

        XCTAssertEqual(WhisperEngine.capped(tokens), tokens)
        XCTAssertEqual(WhisperEngine.capped([]), [])
    }

    /// Расшифровке обязано остаться больше половины контекста: ради этого потолок и введён.
    func testTranscriptKeepsMostOfTheContext() {
        XCTAssertLessThan(WhisperEngine.maxPromptTokens, 224 / 2)
    }
}
