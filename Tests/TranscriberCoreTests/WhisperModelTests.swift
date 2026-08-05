import XCTest
@testable import TranscriberCore

/// Выбор модели Whisper для сессии — его делает только язык.
final class WhisperModelTests: XCTestCase {

    /// Русский идёт на turbo. Он же обслуживает и смешанную речь: замер на семи фикстурах
    /// показал, что украинские вкрапления вытягивает украинский образец в промпте, а не
    /// large-v3, — а large-v3 стоил 5.5× времени прохода.
    func testRussianUsesTurbo() {
        XCTAssertEqual(Language.ru.whisperModel, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(Language.ru.whisperModel, WhisperModel.turbo)
    }

    /// Украинская сессия — большая модель: там она и правда сильнее (13.7 % WER против 22.8 %).
    func testUkrainianUsesLarge() {
        XCTAssertEqual(Language.uk.whisperModel, "openai_whisper-large-v3")
        XCTAssertEqual(Language.uk.whisperModel, WhisperModel.large)
    }

    /// Языки не делят один вариант: иначе кэш движка отдавал бы прогретую не ту модель.
    func testLanguagesPickDifferentVariants() {
        XCTAssertNotEqual(Language.ru.whisperModel, Language.uk.whisperModel)
    }

    /// Смешанная речь на выбор модели не влияет — она живёт целиком в промпте.
    /// Проверяем именно это: промпт русской сессии меняется, а модель — нет.
    func testMixedSpeechChangesPromptNotModel() {
        let plain = PromptBuilder.initialPrompt(entries: [], language: .ru, mixedSpeech: false)
        let mixed = PromptBuilder.initialPrompt(entries: [], language: .ru, mixedSpeech: true)

        XCTAssertNotEqual(plain, mixed)
        XCTAssertTrue(mixed.contains("Українською"))
        XCTAssertFalse(plain.contains("Українською"))
    }
}
