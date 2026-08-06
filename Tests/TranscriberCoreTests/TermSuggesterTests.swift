import XCTest
@testable import TranscriberCore

final class TermSuggesterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    private let entries = [
        DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"]),
        DictionaryEntry(canonical: "pull request", variants: ["пул реквест"]),
    ]

    override func setUpWithError() throws {
        suiteName = "TermSuggesterTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Отбор кандидатов

    func testLatinWordsAreCandidates() {
        let found = TermSuggester.candidates(in: "надо поднять kubernetes на проде", known: [])
        XCTAssertTrue(found.contains("kubernetes"), found.description)
    }

    /// Латиница короче трёх букв — это `ok` и `id`, а не термины.
    func testShortLatinWordsAreNotCandidates() {
        let found = TermSuggester.candidates(in: "ok it is a pr", known: [])
        XCTAssertFalse(found.contains("ok"))
        XCTAssertFalse(found.contains("pr"))
        XCTAssertFalse(found.contains("is"))
        XCTAssertTrue(found.contains("it") == false)
    }

    func testStopWordsAreNotCandidates() {
        let found = TermSuggester.candidates(
            in: "сегодня надо просто сделать работу хорошо",
            known: []
        )
        XCTAssertTrue(found.isEmpty, found.description)
    }

    func testUkrainianStopWordsAreNotCandidates() {
        let found = TermSuggester.candidates(in: "сьогодні треба зробити роботу добре", known: [])
        XCTAssertTrue(found.isEmpty, found.description)
    }

    /// Кириллический жаргон, которого нет ни в словаре, ни в стоп-листе, — кандидат.
    func testUnknownCyrillicJargonIsCandidate() {
        let found = TermSuggester.candidates(in: "прогнали через рэббитмq и кубер", known: [])
        XCTAssertTrue(found.contains("кубер"), found.description)
    }

    /// Финальный текст уже прошёл словарь: канонические формы кандидатами не считаются.
    func testDictionaryTermsAreNotCandidates() {
        let known = TermSuggester.knownTokens(entries)
        let found = TermSuggester.candidates(in: "залил в GitHub и открыл pull request", known: known)
        XCTAssertFalse(found.contains("github"), found.description)
        XCTAssertFalse(found.contains("pull"), found.description)
        XCTAssertFalse(found.contains("request"), found.description)
    }

    /// Многословный термин закрывает и свои отдельные слова.
    func testKnownTokensCoverIndividualWords() {
        let known = TermSuggester.knownTokens(entries)
        XCTAssertTrue(known.contains("pull"))
        XCTAssertTrue(known.contains("request"))
        XCTAssertTrue(known.contains("pull request"))
        XCTAssertTrue(known.contains("гитхаб"))
    }

    /// Цифры и смесь алфавитов терминами не бывают: в словаре им искать нечего.
    func testNumbersAndMixedTokensAreNotCandidates() {
        let found = TermSuggester.candidates(in: "версия 2026 и файл abc123 и кубер2", known: [])
        XCTAssertFalse(found.contains("2026"), found.description)
        XCTAssertFalse(found.contains("abc123"), found.description)
        XCTAssertFalse(found.contains("кубер2"), found.description)
    }

    // MARK: - Порог

    func testCandidateSurfacesOnlyAfterSecondDictation() {
        let suggester = TermSuggester(defaults: defaults)
        suggester.observe("подними kubernetes", entries: entries)
        XCTAssertTrue(suggester.suggestions.isEmpty, "одной диктовки мало")

        suggester.observe("kubernetes опять упал", entries: entries)
        XCTAssertEqual(suggester.suggestions.map(\.token), ["kubernetes"])
        XCTAssertEqual(suggester.suggestions.first?.count, TermSuggester.threshold)
    }

    /// Английская диктовка кандидатов не даёт вовсе: там латиницей написано каждое слово,
    /// и приём «латиница посреди кириллицы — это термин» превращается в «термин — всё».
    func testEnglishDictationProducesNoCandidates() {
        let suggester = TermSuggester(defaults: defaults)
        suggester.observe("check the deploy pipeline tomorrow morning", entries: entries, language: .en)
        suggester.observe("check the deploy pipeline tomorrow morning", entries: entries, language: .en)
        XCTAssertTrue(suggester.suggestions.isEmpty, suggester.suggestions.description)

        // Та же фраза в русской сессии — обычные кандидаты: приём работает там, где задуман.
        suggester.observe("подними kubernetes", entries: entries, language: .ru)
        suggester.observe("kubernetes опять упал", entries: entries, language: .ru)
        XCTAssertEqual(suggester.suggestions.map(\.token), ["kubernetes"])
    }

    /// Повтор внутри ОДНОЙ диктовки порога не даёт: это одно употребление, а не привычка.
    func testRepeatWithinOneDictationCountsOnce() {
        let suggester = TermSuggester(defaults: defaults)
        suggester.observe("kubernetes kubernetes kubernetes", entries: entries)
        XCTAssertTrue(suggester.suggestions.isEmpty, suggester.suggestions.description)
    }

    func testMoreFrequentCandidatesComeFirst() {
        let suggester = TermSuggester(defaults: defaults)
        suggester.observe("kubernetes и terraform", entries: entries)
        suggester.observe("kubernetes и terraform", entries: entries)
        suggester.observe("kubernetes снова", entries: entries)

        XCTAssertEqual(suggester.suggestions.map(\.token), ["kubernetes", "terraform"])
    }

    // MARK: - Игнор и приём

    func testIgnoredCandidateNeverComesBack() {
        let suggester = TermSuggester(defaults: defaults)
        suggester.observe("kubernetes раз", entries: entries)
        suggester.observe("kubernetes два", entries: entries)
        suggester.ignore("kubernetes", entries: entries)
        XCTAssertTrue(suggester.suggestions.isEmpty)

        suggester.observe("kubernetes три", entries: entries)
        suggester.observe("kubernetes четыре", entries: entries)
        XCTAssertTrue(suggester.suggestions.isEmpty, "отклонённое слово больше не предлагается")
    }

    func testAcceptedCandidateDisappears() {
        let suggester = TermSuggester(defaults: defaults)
        suggester.observe("kubernetes раз", entries: entries)
        suggester.observe("kubernetes два", entries: entries)

        let updated = entries + [DictionaryEntry(canonical: "Kubernetes", variants: ["кубернетес"])]
        suggester.accept("kubernetes", entries: updated)
        XCTAssertTrue(suggester.suggestions.isEmpty)
    }

    /// Термин мог попасть в словарь и мимо подсказок — предлагать его второй раз незачем.
    func testRefreshDropsCandidatesThatEnteredTheDictionary() {
        let suggester = TermSuggester(defaults: defaults)
        suggester.observe("kubernetes раз", entries: entries)
        suggester.observe("kubernetes два", entries: entries)
        XCTAssertFalse(suggester.suggestions.isEmpty)

        suggester.refresh(entries: entries + [DictionaryEntry(canonical: "kubernetes", variants: [])])
        XCTAssertTrue(suggester.suggestions.isEmpty)
    }

    // MARK: - Хранение

    func testCountsSurviveRestart() {
        let first = TermSuggester(defaults: defaults)
        first.observe("kubernetes раз", entries: entries)
        first.observe("kubernetes два", entries: entries)

        let second = TermSuggester(defaults: defaults)
        XCTAssertEqual(second.suggestions.map(\.token), ["kubernetes"])
    }

    func testIgnoreListSurvivesRestart() {
        let first = TermSuggester(defaults: defaults)
        first.observe("kubernetes раз", entries: entries)
        first.observe("kubernetes два", entries: entries)
        first.ignore("kubernetes", entries: entries)

        let second = TermSuggester(defaults: defaults)
        second.observe("kubernetes три", entries: entries)
        second.observe("kubernetes четыре", entries: entries)
        XCTAssertTrue(second.suggestions.isEmpty)
    }
}
