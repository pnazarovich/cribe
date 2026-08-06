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

    func testEnglishTemplate() {
        let prompt = PromptBuilder.initialPrompt(entries: entries, language: .en)
        XCTAssertTrue(prompt.hasPrefix("We are discussing "), prompt)
        XCTAssertTrue(prompt.contains("So, let's start: first of all, we check everything — it matters!"), prompt)
        XCTAssertFalse(prompt.contains("Мы обсуждаем"), prompt)
        XCTAssertFalse(prompt.contains("Ми обговорюємо"), prompt)
        // Термины словаря английской сессии нужны так же: они и пишутся латиницей.
        XCTAssertTrue(prompt.contains("GitHub"), prompt)
    }

    // MARK: - Смешанная речь

    /// Образец смешанной речи добавляется только русской сессии: он и нужен затем, чтобы
    /// декодер принимал украинские токены посреди русской диктовки. Украинскую сессию
    /// распознаёт украинская модель, английскую — своя, биасить им нечего.
    func testMixedSampleOnlyInRussianSession() {
        let mixed = PromptBuilder.initialPrompt(entries: entries, language: .ru, mixedSpeech: true)
        XCTAssertTrue(mixed.contains("украинские слова остаются украинскими"), mixed)
        // Образец собран из того же словаря и стоит в самом хвосте — там внимание Whisper.
        XCTAssertTrue(mixed.hasSuffix("снова по-русски про Tailscale."), mixed)

        let plain = PromptBuilder.initialPrompt(entries: entries, language: .ru)
        XCTAssertFalse(plain.contains("украинские слова остаются украинскими"), plain)

        for language in [Language.uk, .en] {
            let other = PromptBuilder.initialPrompt(entries: entries, language: language, mixedSpeech: true)
            XCTAssertFalse(other.contains("украинские слова остаются украинскими"), other)
        }
    }

    /// Главное свойство образца: доминирующий язык остаётся доминирующим. Образец, целиком
    /// написанный по-украински, декодер принимал за язык всей записи и возвращал русскую
    /// основу украинской («я сьогодні посмотрел, що там з сервером»). Поэтому в образце
    /// украинского — меньшая часть, а начало и конец русские: хвост промпта задаёт тон
    /// первому слову речи.
    func testMixedSampleStaysRussianDominant() {
        let prompt = PromptBuilder.initialPrompt(entries: [], language: .ru, mixedSpeech: true)
        let sample = String(prompt.dropFirst("Итак, начнём: во-первых, проверим всё — это важно! ".count))

        XCTAssertTrue(sample.hasPrefix("Говорим по-русски"), sample)
        XCTAssertTrue(sample.hasSuffix("по-русски про задачи."), sample)

        // Украинские буквы есть — вкрапление настоящее, а не пересказ про него.
        XCTAssertTrue(sample.contains(where: { "їієґ".contains($0) }), sample)

        // И их меньшинство: считаем слова с украинскими признаками против всех слов.
        let words = sample.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
        let ukrainian = words.filter { word in
            word.contains(where: { "їієґ".contains($0) }) || word.contains("'")
        }
        XCTAssertGreaterThan(words.count, 2 * ukrainian.count, "русская часть обязана быть больше украинской")
    }

    func testMixedPromptWithEmptyDictionaryStillCarriesSample() {
        let prompt = PromptBuilder.initialPrompt(entries: [], language: .ru, mixedSpeech: true)
        XCTAssertTrue(prompt.contains("Итак, начнём"), prompt)
        XCTAssertTrue(prompt.contains("перевірити налаштування"), prompt)
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
        XCTAssertTrue(prompt.hasSuffix("снова по-русски про Terminus100."), prompt)
    }
}
