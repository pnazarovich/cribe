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

    // MARK: - Смешанная речь

    /// Образец смешанной речи добавляется только русской сессии: он и нужен затем, чтобы
    /// декодер принимал украинские токены посреди русской диктовки. Украинскую сессию
    /// распознаёт украинская модель, английскую — своя, биасить им нечего.
    func testMixedSampleOnlyInRussianSession() {
        let mixed = PromptBuilder.initialPrompt(entries: entries, language: .ru, mixedSpeech: true)
        XCTAssertTrue(mixed.contains("треба ще перевірити налаштування"), mixed)
        // Термины остаются на месте — русской рамкой образцу служат именно они.
        XCTAssertTrue(mixed.hasPrefix("Говорим по-русски про GitHub, Tailscale:"), mixed)
        // Кончается промпт по-русски: хвост задаёт тон первому слову речи.
        XCTAssertTrue(mixed.hasSuffix("— и дальше снова по-русски."), mixed)

        let plain = PromptBuilder.initialPrompt(entries: entries, language: .ru)
        XCTAssertFalse(plain.contains("треба ще перевірити налаштування"), plain)

        for language in [Language.uk, .en] {
            let other = PromptBuilder.initialPrompt(entries: entries, language: language, mixedSpeech: true)
            XCTAssertFalse(other.contains("треба ще перевірити налаштування"), other)
        }
    }

    /// Образец занимает место образца пунктуации, а не добавляется к нему: у промпта
    /// ~64 токена окна, и на оба сразу их не хватает — вместе они не оставляли места
    /// ни одному термину словаря.
    func testMixedSampleReplacesPunctuationSample() {
        let mixed = PromptBuilder.initialPrompt(entries: entries, language: .ru, mixedSpeech: true)

        XCTAssertFalse(mixed.contains("Итак, начнём"), mixed)
        XCTAssertTrue(mixed.contains("GitHub"), mixed)
    }

    /// Главное свойство образца: доминирующий язык остаётся доминирующим. Образец, целиком
    /// написанный по-украински, декодер принимал за язык всей записи и возвращал русскую
    /// основу украинской («я сьогодні посмотрел, що там з сервером»). Поэтому в образце
    /// украинского — меньшая часть, а начало и конец русские: хвост промпта задаёт тон
    /// первому слову речи.
    func testMixedSampleStaysRussianDominant() {
        let sample = PromptBuilder.initialPrompt(entries: [], language: .ru, mixedSpeech: true)

        XCTAssertTrue(sample.hasPrefix("Говорим по-русски"), sample)
        XCTAssertTrue(sample.hasSuffix("и дальше снова по-русски."), sample)

        // Украинские буквы есть — вкрапление настоящее, а не пересказ про него.
        XCTAssertTrue(sample.contains(where: { "їієґ".contains($0) }), sample)

        // И их меньшинство: считаем слова с украинскими признаками против всех слов.
        let words = sample.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
        let ukrainian = words.filter { word in
            word.contains(where: { "їієґ".contains($0) }) || word.contains("'")
        }
        XCTAssertGreaterThan(words.count, 2 * ukrainian.count, "русская часть обязана быть больше украинской")
    }

    /// Словарь пуст — образец всё равно нужен, и рамкой ему служит собственное начало.
    func testMixedPromptWithEmptyDictionaryStillCarriesSample() {
        let prompt = PromptBuilder.initialPrompt(entries: [], language: .ru, mixedSpeech: true)
        XCTAssertEqual(
            prompt,
            "Говорим по-русски: «треба ще перевірити налаштування, а тоді вже з'ясуємо деталі», "
                + "— и дальше снова по-русски."
        )
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
        XCTAssertTrue(prompt.contains("Terminus100:"), prompt)
        XCTAssertFalse(prompt.contains("Terminus1,"), prompt)
    }
}
