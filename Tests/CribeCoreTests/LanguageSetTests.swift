import XCTest
@testable import CribeCore

/// Набор языков вместо одного.
///
/// Раньше язык был один и приказывал распознаванию, а смешанная речь жила отдельной
/// галочкой. С Ultra без подсказки письменности распознавание само слышит язык, поэтому
/// отмечать можно любое сочетание, а язык каждой диктовки берётся по её тексту.
final class LanguageSetTests: XCTestCase {

    // MARK: Язык диктовки по тексту

    func testSingleLanguageIsJustThatLanguage() {
        XCTAssertEqual(Language.resolve("Hello there", among: [.ru]), .ru, "отмечен один — он и есть, что бы ни звучало")
        XCTAssertEqual(Language.resolve("ще раз", among: [.uk]), .uk)
    }

    func testWholeUkrainianOrRussianPhrasesAreToldApart() {
        let both: Set<Language> = [.ru, .uk]
        XCTAssertEqual(Language.resolve("Мы были в этом городе ещё вчера", among: both), .ru)
        XCTAssertEqual(
            Language.resolve("Ми з колегами вирішили перенести зустріч на четвер, бо в середу всі зайняті", among: both),
            .uk
        )
        XCTAssertEqual(Language.resolve("Дякую, гаразд", among: both), .uk, "коротко, но слова однозначные")
        XCTAssertEqual(Language.resolve("Добре, зроблю завтра", among: both), .uk)
    }

    /// Русская фраза с украинскими вставками остаётся русской — это и есть смешанная речь.
    /// Первая версия считала буквы и уводила «Слушай, там нічого не работает» в украинский:
    /// одна «і», ни одной «ы».
    func testRussianWithUkrainianInsertsStaysRussian() {
        let both: Set<Language> = [.ru, .uk]
        XCTAssertEqual(Language.resolve("Слушай, там нічого не работает", among: both), .ru)
        XCTAssertEqual(Language.resolve("Я вчера нічого не зрозумів в этом коде", among: both), .ru)
        XCTAssertEqual(
            Language.resolve("Ну вот, я посмотрел, що там с сервером, и вы были правы", among: both),
            .ru
        )
    }

    /// Ничья — первый отмеченный: на «да» различать нечего.
    func testTieGoesToTheFirstEnabled() {
        XCTAssertEqual(Language.resolve("да", among: [.ru, .uk]), .ru)
        XCTAssertEqual(Language.resolve("так", among: [.uk, .en]), .uk)
    }

    /// Английский — только когда кириллицы почти нет. Первая версия хватала английский при
    /// простом перевесе латиницы, и русская фраза с названиями уходила английской — а перевод
    /// на английский при этом молча снимался.
    func testRussianWithEnglishNamesStaysRussian() {
        let mixed: Set<Language> = [.ru, .en]
        XCTAssertEqual(Language.resolve("Короче, сделай pull request в GitHub", among: mixed), .ru)
        XCTAssertEqual(Language.resolve("открой Google Ads и PostHog", among: mixed), .ru)
        XCTAssertEqual(Language.resolve("Задеплой на Vercel, проверь GitHub Actions и PostHog", among: mixed), .ru)
        XCTAssertEqual(Language.resolve("Запушь в main и сделай deploy на Vercel", among: mixed), .ru)
    }

    func testEnglishPhrasesAreEnglish() {
        XCTAssertEqual(Language.resolve("Please check the deploy logs", among: [.ru, .en]), .en)
        XCTAssertEqual(Language.resolve("Check the logs please", among: [.ru, .uk, .en]), .en)
        XCTAssertEqual(
            Language.resolve("Call Ярополк about the deploy tomorrow morning", among: [.ru, .en]),
            .en,
            "одно русское имя английскую фразу не перекрашивает"
        )
    }

    // MARK: Подсказка распознаванию

    /// Английская подсказка включает фильтр, отсекающий кириллицу, поэтому — только когда
    /// английский отмечен один. При «русский + английский» она выкинула бы всю русскую речь.
    func testRecognitionHintNeverFiltersCyrillicAway() {
        XCTAssertEqual(Language.recognition(for: [.en]), .en)
        XCTAssertEqual(Language.recognition(for: [.ru, .en]), .ru)
        XCTAssertEqual(Language.recognition(for: [.uk, .en]), .uk)
        XCTAssertEqual(Language.recognition(for: [.ru, .uk, .en]), .ru)
        XCTAssertNil(ParakeetEngine.scriptHint(for: Language.recognition(for: [.ru, .en])))
    }

    func testDisplayNameFollowsMenuOrder() {
        XCTAssertEqual(Language.displayName(of: [.en, .ru]), "Русский + English")
        XCTAssertEqual(Language.displayName(of: [.uk]), "Українська")
    }
}
