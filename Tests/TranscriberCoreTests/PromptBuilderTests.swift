import XCTest
@testable import TranscriberCore

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
}
