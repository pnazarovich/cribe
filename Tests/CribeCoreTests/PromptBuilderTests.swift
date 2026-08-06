import XCTest
@testable import CribeCore

final class PromptBuilderTests: XCTestCase {
    private let entries = [
        DictionaryEntry(canonical: "GitHub", variants: ["гитхаб"]),
        DictionaryEntry(canonical: "Tailscale", variants: ["тейлскейл"]),
    ]

    func testContainsCanonicalTerms() {
        let prompt = PromptBuilder.initialPrompt(entries: entries, language: .ru)
        XCTAssertTrue(prompt.contains("GitHub"), prompt)
        XCTAssertTrue(prompt.contains("Tailscale"), prompt)
    }

    func testTermsAreEmbeddedInSentenceNotBareList() {
        let prompt = PromptBuilder.initialPrompt(entries: entries, language: .ru)
        XCTAssertTrue(prompt.hasPrefix("Мы обсуждаем "), prompt)
        XCTAssertTrue(prompt.contains("Итак, начнём: во-первых, проверим всё — это важно!"), prompt)
    }

    func testUkrainianTemplate() {
        let prompt = PromptBuilder.initialPrompt(entries: entries, language: .uk)
        XCTAssertTrue(prompt.hasPrefix("Ми обговорюємо "), prompt)
        XCTAssertTrue(prompt.contains("Отже, почнімо: по-перше, перевіримо все — це важливо!"), prompt)
        XCTAssertFalse(prompt.contains("Мы обсуждаем"), prompt)
    }

    func testMaxTermsLimitsNumberOfTerms() {
        let many = (1...10).map { DictionaryEntry(canonical: "Term\($0)", variants: ["терм\($0)"]) }
        let prompt = PromptBuilder.initialPrompt(entries: many, language: .ru, maxTerms: 3)
        XCTAssertTrue(prompt.contains("Term1"), prompt)
        XCTAssertTrue(prompt.contains("Term3"), prompt)
        XCTAssertFalse(prompt.contains("Term4"), prompt)
    }

    func testLengthBudgetDropsEarliestTermsFirst() {
        let many = (1...100).map {
            DictionaryEntry(canonical: "Terminus\($0)", variants: ["термінус\($0)"])
        }
        let prompt = PromptBuilder.initialPrompt(entries: many, language: .ru, maxTerms: 100)
        XCTAssertLessThanOrEqual(prompt.count, 700, prompt)
        XCTAssertTrue(prompt.contains("Terminus100"), prompt)
        XCTAssertFalse(prompt.contains("Terminus1,"), prompt)
    }

    func testEmptyDictionaryStillProducesPunctuationSample() {
        let prompt = PromptBuilder.initialPrompt(entries: [], language: .ru)
        XCTAssertEqual(prompt, "Итак, начнём: во-первых, проверим всё — это важно!")
    }

    func testEnglishTemplate() {
        let prompt = PromptBuilder.initialPrompt(entries: entries, language: .en)
        XCTAssertTrue(prompt.hasPrefix("We are discussing "), prompt)
        XCTAssertTrue(prompt.contains("So, let's start: first of all, we check everything — it matters!"), prompt)
        XCTAssertFalse(prompt.contains("Мы обсуждаем"), prompt)
        XCTAssertFalse(prompt.contains("Ми обговорюємо"), prompt)
        // Термины словаря английской сессии нужны так же: они и пишутся латиницей.
        XCTAssertTrue(prompt.contains("GitHub"), prompt)
    }

    // MARK: - Язык промпта

    /// Промпт русской сессии обязан быть русским целиком — ни одного украинского слова.
    /// Здесь когда-то жил образец смешанной речи с украинской вставкой, и на настоящей
    /// (не синтезированной) диктовке он работал переключателем языка: русская запись
    /// возвращалась целиком по-украински. Термины словаря к этому отношения не имеют —
    /// они и должны быть латиницей, — поэтому проверяем только кириллицу промпта.
    func testRussianPromptCarriesNoUkrainianLetters() {
        let ukrainianOnly: Set<Character> = ["і", "І", "ї", "Ї", "є", "Є", "ґ", "Ґ"]
        let prompts = [
            PromptBuilder.initialPrompt(entries: entries, language: .ru),
            PromptBuilder.initialPrompt(entries: [], language: .ru),
        ]

        for prompt in prompts {
            XCTAssertFalse(prompt.contains(where: { ukrainianOnly.contains($0) }), prompt)
        }
    }

    /// Украинской сессии украинские буквы, наоборот, положены: её промпт — украинский.
    func testUkrainianPromptDoesCarryUkrainianLetters() {
        let prompt = PromptBuilder.initialPrompt(entries: entries, language: .uk)

        XCTAssertTrue(prompt.contains(where: { "їієґ".contains($0) }), prompt)
    }
}
