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

    // MARK: - Смешанная речь

    /// Украинский образец добавляется только русской сессии со смешанной речью: он и нужен
    /// затем, чтобы декодер принимал украинские токены посреди русской диктовки.
    func testUkrainianSampleOnlyInMixedRussian() {
        let mixed = PromptBuilder.initialPrompt(entries: entries, language: .ru, mixedSpeech: true)
        XCTAssertTrue(mixed.contains("Українською кажемо так"), mixed)
        // Образец собран из того же словаря и стоит в самом хвосте — там внимание Whisper.
        XCTAssertTrue(mixed.hasSuffix("що робити з Tailscale."), mixed)

        let plain = PromptBuilder.initialPrompt(entries: entries, language: .ru)
        XCTAssertFalse(plain.contains("Українською кажемо так"), plain)

        // Украинскую сессию и так распознаёт украинская модель — биасить ей нечего.
        let ukrainian = PromptBuilder.initialPrompt(entries: entries, language: .uk, mixedSpeech: true)
        XCTAssertFalse(ukrainian.contains("Українською кажемо так"), ukrainian)
    }

    func testMixedPromptWithEmptyDictionaryStillCarriesUkrainianSample() {
        let prompt = PromptBuilder.initialPrompt(entries: [], language: .ru, mixedSpeech: true)
        XCTAssertTrue(prompt.contains("Итак, начнём"), prompt)
        XCTAssertTrue(prompt.contains("Українською кажемо так"), prompt)
    }

    /// Образец не имеет права проесть бюджет промпта: режем термины ровно так же.
    func testMixedPromptKeepsLengthBudget() {
        let many = (1...100).map {
            DictionaryEntry(canonical: "Terminus\($0)", variants: ["термінус\($0)"])
        }
        let prompt = PromptBuilder.initialPrompt(
            entries: many, language: .ru, maxTerms: 100, mixedSpeech: true
        )
        XCTAssertLessThanOrEqual(prompt.count, 700, prompt)
        XCTAssertTrue(prompt.hasSuffix("що робити з Terminus100."), prompt)
    }
}
