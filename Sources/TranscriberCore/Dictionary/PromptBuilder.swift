import Foundation

/// Слой 1: initial_prompt для Whisper — термины внутри естественных предложений
/// (голый список через запятую провоцирует галлюцинации) + образец пунктуации.
public enum PromptBuilder {
    /// Грубая оценка лимита: ≤ 200 токенов ≈ 700 символов.
    private static let maxCharacters = 700

    public static func initialPrompt(
        entries: [DictionaryEntry],
        language: Language,
        maxTerms: Int = 50
    ) -> String {
        var terms = entries.prefix(maxTerms).map(\.canonical)
        guard !terms.isEmpty else { return punctuationSample(language) }

        var prompt = compose(terms: terms, language: language)
        // Внимание Whisper смещено к хвосту промпта: важные термины — в конце,
        // поэтому под лимит режем с начала списка.
        while prompt.count > maxCharacters, terms.count > 1 {
            terms.removeFirst()
            prompt = compose(terms: terms, language: language)
        }
        return prompt
    }

    private static func compose(terms: [String], language: Language) -> String {
        let list = terms.joined(separator: ", ")
        switch language {
        case .ru:
            return "Мы обсуждаем \(list) и делаем deploy в продакшен. \(punctuationSample(.ru))"
        case .uk:
            return "Ми обговорюємо \(list) і робимо deploy у продакшен. \(punctuationSample(.uk))"
        }
    }

    private static func punctuationSample(_ language: Language) -> String {
        switch language {
        case .ru: return "Итак, начнём: во-первых, проверим всё — это важно!"
        case .uk: return "Отже, почнімо: по-перше, перевіримо все — це важливо!"
        }
    }
}
