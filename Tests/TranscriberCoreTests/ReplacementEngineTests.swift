import XCTest
@testable import TranscriberCore

final class ReplacementEngineTests: XCTestCase {
    private let github = DictionaryEntry(canonical: "GitHub", variants: ["гитхаб", "гит хаб"])
    private let deploy = DictionaryEntry(canonical: "deploy", variants: ["деплой"])
    private let tailscale = DictionaryEntry(canonical: "Tailscale", variants: ["тейлскейл"])
    private let api = DictionaryEntry(canonical: "API", variants: ["апи"], stem: false)

    // MARK: - Склонения

    func testRussianInflections() {
        XCTAssertEqual(
            ReplacementEngine.apply("вчера не было деплоя", entries: [deploy]),
            "вчера не было deploy"
        )
        XCTAssertEqual(
            ReplacementEngine.apply("код лежит в гитхабе", entries: [github]),
            "код лежит в GitHub"
        )
        XCTAssertEqual(
            ReplacementEngine.apply("хожу тейлскейлом", entries: [tailscale]),
            "хожу Tailscale"
        )
    }

    func testUkrainianInflectionsAndLetters() {
        let commit = DictionaryEntry(canonical: "commit", variants: ["коміт"])
        let githubUA = DictionaryEntry(canonical: "GitHub", variants: ["гіт хаб"])
        XCTAssertEqual(
            ReplacementEngine.apply("у коміті є зміни", entries: [commit]),
            "у commit є зміни"
        )
        XCTAssertEqual(
            ReplacementEngine.apply("подивись у гіт хабі", entries: [githubUA]),
            "подивись у GitHub"
        )
    }

    // MARK: - Регистр

    func testCaseInsensitiveMatchingProducesCanonicalCase() {
        XCTAssertEqual(ReplacementEngine.apply("Гитхаб упал", entries: [github]), "GitHub упал")
        XCTAssertEqual(ReplacementEngine.apply("ГИТХАБ упал", entries: [github]), "GitHub упал")
    }

    // MARK: - Границы слова

    func testPrefixedWordIsNotReplaced() {
        XCTAssertEqual(
            ReplacementEngine.apply("надо загитхабить это", entries: [github]),
            "надо загитхабить это"
        )
    }

    func testNonStemEntryDoesNotMatchSuffixedWord() {
        XCTAssertEqual(ReplacementEngine.apply("дёрни апи", entries: [api]), "дёрни API")
        XCTAssertEqual(ReplacementEngine.apply("дёрни апишку", entries: [api]), "дёрни апишку")
    }

    func testShortStemVariantDoesNotOvermatchUnrelatedWord() {
        // Основа «стал» (после отбрасывания -ь) съела бы «сталкер» — она слишком коротка.
        let steel = DictionaryEntry(canonical: "Steel", variants: ["сталь"])
        XCTAssertEqual(
            ReplacementEngine.apply("мимо шёл сталкер", entries: [steel]),
            "мимо шёл сталкер"
        )
        XCTAssertEqual(ReplacementEngine.apply("нужна сталь", entries: [steel]), "нужна Steel")
    }

    func testVeryShortVariantsNeverProduceEmptyCorePattern() {
        // Пустая основа дала бы паттерн, матчащий ЛЮБОЕ слово.
        let single = DictionaryEntry(canonical: "J", variants: ["й"])
        let double = DictionaryEntry(canonical: "Oy", variants: ["ой"])
        XCTAssertEqual(
            ReplacementEngine.apply("любой обычный текст", entries: [single, double]),
            "любой обычный текст"
        )
    }

    // MARK: - Несколько вхождений

    func testMultipleOccurrences() {
        XCTAssertEqual(
            ReplacementEngine.apply("деплой, потом ещё деплой и деплоим снова", entries: [deploy]),
            "deploy, потом ещё deploy и deploy снова"
        )
    }

    // MARK: - Пустой словарь

    func testEmptyDictionaryLeavesTextUnchanged() {
        let text = "деплой в гитхаб"
        XCTAssertEqual(ReplacementEngine.apply(text, entries: []), text)
        XCTAssertEqual(
            ReplacementEngine.apply(text, entries: [DictionaryEntry(canonical: "X", variants: [])]),
            text
        )
    }

    // MARK: - Приоритет длинного варианта

    func testLongerVariantWins() {
        let git = DictionaryEntry(canonical: "git", variants: ["гит"])
        XCTAssertEqual(
            ReplacementEngine.apply("открой гит хаб", entries: [git, github]),
            "открой GitHub"
        )
    }

    func testEqualLengthVariantsResolveDeterministically() {
        let first = DictionaryEntry(canonical: "A", variants: ["деплой"])
        let second = DictionaryEntry(canonical: "B", variants: ["деплоя"])
        let direct = ReplacementEngine.apply("сделал деплоя", entries: [first, second])
        let reversed = ReplacementEngine.apply("сделал деплоя", entries: [second, first])
        XCTAssertEqual(direct, reversed)
        XCTAssertEqual(direct, "сделал A") // алфавитный tie-break: «деплой» < «деплоя»
    }

    // MARK: - Стартовый словарь

    func testDefaultEntriesOnRealisticSentence() {
        XCTAssertEqual(
            ReplacementEngine.apply("надо закоммить в гитхаб и задеплоить на впс", entries: defaultEntries),
            "надо commit в GitHub и deploy на VPS"
        )
    }
}
