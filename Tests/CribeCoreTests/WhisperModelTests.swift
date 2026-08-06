import XCTest
@testable import CribeCore

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

    /// Английская сессия идёт на turbo — той же самой, что у русского. Это не мелочь
    /// раскладки: у кого скачан русский, у того английский уже скачан, и вторых 1,5 ГБ
    /// третий язык не стоит.
    func testEnglishSharesTheRussianVariant() {
        XCTAssertEqual(Language.en.whisperModel, WhisperModel.turbo)
        XCTAssertEqual(Language.en.whisperModel, Language.ru.whisperModel)
        XCTAssertNotEqual(Language.en.whisperModel, Language.uk.whisperModel)
    }

    /// Модель — единица скачивания, язык — нет: turbo обслуживает русский и английский,
    /// large-v3 — украинский. Каждый язык попадает ровно в одну модель.
    func testBundlesGroupLanguagesByVariant() {
        XCTAssertEqual(ModelBundle.all.map(\.variant), [WhisperModel.turbo, WhisperModel.large])
        XCTAssertEqual(ModelBundle.all.map(\.languages), [[.ru, .en], [.uk]])
        XCTAssertEqual(Set(ModelBundle.all.flatMap(\.languages)), Set(Language.allCases))
        XCTAssertEqual(ModelBundle.bundle(for: .en), ModelBundle.bundle(for: .ru))
        XCTAssertEqual(ModelBundle.bundle(for: .ru).displayName, "Русский · English")
    }

    /// Размер модели — не украшение подписи, а само основание качать модели по отдельности:
    /// украинская вдвое тяжелее, и тому, кому нужен только русский, эти гигабайты навязывать
    /// нечем. Первый запуск называет числа до нажатия кнопки — и у общей модели число одно.
    func testModelSizeIsNamedPerModelAndUkrainianIsHeavier() {
        XCTAssertEqual(ModelBundle.bundle(for: .ru).sizeGB, 1.5, accuracy: 0.01)
        XCTAssertEqual(ModelBundle.bundle(for: .uk).sizeGB, 2.9, accuracy: 0.01)
        XCTAssertGreaterThan(ModelBundle.bundle(for: .uk).sizeGB, ModelBundle.bundle(for: .ru).sizeGB)
        // Английский не добавляет ни гигабайта: это та же модель, что у русского.
        XCTAssertEqual(ModelBundle.bundle(for: .en).sizeGB, ModelBundle.bundle(for: .ru).sizeGB)

        XCTAssertEqual(ModelBundle.bundle(for: .ru).sizeText, "1,5 ГБ")
        XCTAssertEqual(ModelBundle.bundle(for: .uk).sizeText, "2,9 ГБ")
        for bundle in ModelBundle.all {
            XCTAssertTrue(bundle.sizeText.hasSuffix(" ГБ"), "единица измерения обязана быть видна")
        }
    }

    /// Русская сессия работает на turbo, украинская — на large-v3, и выбор этот делает
    /// только язык. Смешанной речи среди оснований больше нет: моделью её не лечат
    /// (см. `WhisperModel`), а промптом — тем более (см. `PromptBuilder`).
    func testModelIsChosenByLanguageAlone() {
        XCTAssertEqual(Language.ru.whisperModel, WhisperModel.turbo)
        XCTAssertEqual(Language.en.whisperModel, WhisperModel.turbo)
        XCTAssertEqual(Language.uk.whisperModel, WhisperModel.large)
    }
}
