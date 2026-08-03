import Foundation

/// Слой 1: initial_prompt для Whisper — термины внутри естественных предложений
/// (голый список через запятую провоцирует галлюцинации) + образец пунктуации.
public enum PromptBuilder {
    /// Грубая оценка лимита: ≤ 200 токенов ≈ 700 символов.
    private static let maxCharacters = 700

    public static func initialPrompt(
        entries: [DictionaryEntry],
        language: Language,
        maxTerms: Int = 50,
        mixedSpeech: Bool = false
    ) -> String {
        // Украинский образец нужен только русским сессиям смешанной речи: украинская сессия
        // и так распознаётся украинской моделью, ей биасить нечего.
        let mixed = mixedSpeech && language == .ru
        var terms = entries.prefix(maxTerms).map(\.canonical)
        guard !terms.isEmpty else {
            let base = punctuationSample(language)
            return mixed ? base + " " + ukrainianSample(term: nil) : base
        }

        var prompt = compose(terms: terms, language: language, mixed: mixed)
        // Внимание Whisper смещено к хвосту промпта: важные термины — в конце,
        // поэтому под лимит режем с начала списка.
        while prompt.count > maxCharacters, terms.count > 1 {
            terms.removeFirst()
            prompt = compose(terms: terms, language: language, mixed: mixed)
        }
        return prompt
    }

    private static func compose(terms: [String], language: Language, mixed: Bool) -> String {
        let list = terms.joined(separator: ", ")
        switch language {
        case .ru:
            let base = "Мы обсуждаем \(list) и делаем deploy в продакшен. \(punctuationSample(.ru))"
            return mixed ? base + " " + ukrainianSample(term: terms.last) : base
        case .uk:
            return "Ми обговорюємо \(list) і робимо deploy у продакшен. \(punctuationSample(.uk))"
        }
    }

    /// Одно украинское предложение в самом хвосте русского промпта: внимание Whisper смещено
    /// к концу, и такой образец показывает декодеру, что украинские токены посреди русской
    /// речи — норма. Термин берём из того же словаря — тот, что ближе к хвосту, то есть
    /// самый «важный» по той же логике, по которой список режется с начала.
    ///
    /// Формулировка нарочно не похожа на рабочую фразу: Whisper склонен доигрывать промпт,
    /// и образец вида «…і зробити коміт.» обрывал настоящую диктовку на этом же месте
    /// (замерено на «…зробити коміт у гілку» — хвост пропадал целиком).
    private static func ukrainianSample(term: String?) -> String {
        let subject = term ?? "справи"
        return "Українською кажемо так: спершу з'ясуємо деталі, а тоді вирішимо, що робити з \(subject)."
    }

    private static func punctuationSample(_ language: Language) -> String {
        switch language {
        case .ru: return "Итак, начнём: во-первых, проверим всё — это важно!"
        case .uk: return "Отже, почнімо: по-перше, перевіримо все — це важливо!"
        }
    }
}
