import XCTest
@testable import CribeCore

/// Язык перевода и то, как он доезжает до подсказки модели.
///
/// Раньше цель была одна — английский, и жила она булевым флагом `translateToEnglish`.
/// Флаг честно описывал, что делает правый ⌥, ровно до того дня, когда переводить
/// понадобилось на польский.
final class TranslationTargetTests: XCTestCase {

    /// Список задаёт польза, а не техника: переводит GPT, и ему всё равно, какой язык
    /// просить. Польский тут по прямой просьбе владельца.
    func testTargetsCoverTwentyLanguagesIncludingPolish() {
        XCTAssertEqual(TranslationTarget.allCases.count, 20)
        XCTAssertTrue(TranslationTarget.allCases.contains(.pl))
        XCTAssertEqual(TranslationTarget.pl.displayName, "Польский")
        XCTAssertEqual(TranslationTarget.pl.promptName, "Polish")

        for target in TranslationTarget.allCases {
            XCTAssertFalse(target.displayName.isEmpty, "\(target)")
            XCTAssertFalse(target.promptName.isEmpty, "\(target)")
            // Имя для модели — по-английски: русское «нидерландский» рядом с «голландский»
            // уже повод гадать, а английское — нет.
            XCTAssertTrue(
                target.promptName.allSatisfy { $0.isASCII },
                "\(target): имя для модели обязано быть латиницей — \(target.promptName)"
            )
        }
    }

    /// Название после предлога «на» склонять не приходится: в списке либо прилагательные
    /// на «-ский», у которых винительный совпадает с именительным, либо несклоняемые
    /// существительные.
    func testNameAfterPrepositionIsJustLowercased() {
        XCTAssertEqual(TranslationTarget.pl.afterOn, "польский")
        XCTAssertEqual(TranslationTarget.he.afterOn, "иврит")
        XCTAssertEqual(TranslationTarget.hi.afterOn, "хинди")
    }

    /// Цель совпала с языком диктовки — переводить нечего.
    func testTargetMatchingTheDictationLanguage() {
        XCTAssertTrue(TranslationTarget.ru.matches(.ru))
        XCTAssertTrue(TranslationTarget.uk.matches(.uk))
        XCTAssertTrue(TranslationTarget.en.matches(.en))
        XCTAssertFalse(TranslationTarget.pl.matches(.ru))
        XCTAssertFalse(TranslationTarget.en.matches(.ru))
    }

    /// Язык перевода доезжает до подсказки — и именно английским названием.
    func testPromptNamesTheTargetLanguage() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        for language in [Language.ru, .uk, .en] {
            let prompt = PostProcessor.systemPrompt(entries: entries, language: language, translateTo: .pl)
            XCTAssertTrue(prompt.contains("Polish"), "\(language): \(prompt)")
        }
        // На русской и украинской сессиях английского в подсказке не остаётся вовсе:
        // раньше он был вписан в неё как единственная цель. На английской он законно
        // стоит как ЯЗЫК ДИКТОВКИ, и там эта проверка ничего не значила бы.
        for language in [Language.ru, .uk] {
            let prompt = PostProcessor.systemPrompt(entries: entries, language: language, translateTo: .pl)
            XCTAssertFalse(prompt.contains("English"), "\(language): цель одна, и это не английский")
        }
    }

    /// Просить перевести текст на его же язык нельзя: вместо текста придёт пересказ.
    /// Промпт в этом случае обязан быть ровно тем же, что и без перевода.
    func testTranslatingIntoTheOwnLanguageIsNoTranslationAtAll() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        for (language, target) in [(Language.ru, TranslationTarget.ru), (.uk, .uk), (.en, .en)] {
            XCTAssertEqual(
                PostProcessor.systemPrompt(entries: entries, language: language, translateTo: target),
                PostProcessor.systemPrompt(entries: entries, language: language),
                "\(language)"
            )
        }
    }

    /// Английская диктовка теперь тоже переводится. Раньше перевод отсюда был выключен
    /// наглухо, и это было верно ровно пока цель была одна.
    func testEnglishDictationTranslatesToOtherLanguages() {
        let entries = [DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"])]
        let prompt = PostProcessor.systemPrompt(entries: entries, language: .en, translateTo: .pl)
        XCTAssertTrue(prompt.contains("translate it into Polish"), prompt)
        // Правило про базовый язык на переводе обязано звучать иначе, иначе оно спорит
        // с самим переводом.
        XCTAssertFalse(prompt.contains("never translate it into another language"), prompt)
    }

    /// Тире просили дефисом — правило есть в подсказке на всех трёх языках инструкций.
    func testDashRuleIsInEveryPrompt() {
        let entries: [DictionaryEntry] = []
        XCTAssertTrue(PostProcessor.systemPrompt(entries: entries, language: .ru).contains("обычным дефисом"))
        XCTAssertTrue(PostProcessor.systemPrompt(entries: entries, language: .uk).contains("звичайним дефісом"))
        XCTAssertTrue(PostProcessor.systemPrompt(entries: entries, language: .en).contains("plain hyphen"))
    }

    /// И не только правило. Подсказку про типографику модель роняет чаще прочих — она
    /// спорит с её привычкой писать «красиво», — поэтому тире снимается ещё и разбором
    /// ответа, где результат от настроения модели не зависит вовсе.
    func testLongDashesAreReplacedInTheAnswer() {
        XCTAssertEqual(
            PostProcessor.withPlainDashes("Cribe — это диктовка, а не — редактор"),
            "Cribe - это диктовка, а не - редактор"
        )
        XCTAssertEqual(PostProcessor.withPlainDashes("2020–2024"), "2020-2024")
        XCTAssertEqual(PostProcessor.withPlainDashes("уже-дефис"), "уже-дефис")
        XCTAssertEqual(PostProcessor.withPlainDashes(""), "")
    }
}
