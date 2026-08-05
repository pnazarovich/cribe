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

    /// Размер модели — не украшение подписи, а само основание качать языки по отдельности:
    /// украинская вдвое тяжелее русской, и тому, кому нужен только русский, эти гигабайты
    /// навязывать нечем. Первый запуск называет числа до нажатия кнопки.
    func testModelSizeIsNamedPerLanguageAndUkrainianIsHeavier() {
        XCTAssertEqual(Language.ru.modelSizeGB, 1.5, accuracy: 0.01)
        XCTAssertEqual(Language.uk.modelSizeGB, 2.9, accuracy: 0.01)
        XCTAssertGreaterThan(Language.uk.modelSizeGB, Language.ru.modelSizeGB)

        XCTAssertEqual(Language.ru.modelSizeText, "1,5 ГБ")
        XCTAssertEqual(Language.uk.modelSizeText, "2,9 ГБ")
        for language in Language.allCases {
            XCTAssertTrue(language.modelSizeText.hasSuffix(" ГБ"), "единица измерения обязана быть видна")
        }
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
