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
        // Смешанный образец нужен только русским сессиям: украинская сессия распознаётся
        // украинской моделью, английская — своя, биасить им нечего.
        let mixed = mixedSpeech && language == .ru
        var terms = entries.prefix(maxTerms).map(\.canonical)
        guard !terms.isEmpty else {
            let base = punctuationSample(language)
            return mixed ? base + " " + mixedSample(term: nil) : base
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
            return mixed ? base + " " + mixedSample(term: terms.last) : base
        case .uk:
            return "Ми обговорюємо \(list) і робимо deploy у продакшен. \(punctuationSample(.uk))"
        case .en:
            return "We are discussing \(list) and shipping a deploy to production. \(punctuationSample(.en))"
        }
    }

    /// Образец смешанной речи в самом хвосте русского промпта: внимание Whisper смещено
    /// к концу, и такой образец показывает декодеру, что украинские токены посреди русской
    /// речи — норма. Термин берём из того же словаря — тот, что ближе к хвосту, то есть
    /// самый «важный» по той же логике, по которой список режется с начала.
    ///
    /// Устройство образца — та же пропорция, что у настоящей диктовки: русская рамка, внутри
    /// неё один связный украинский кусок, и кончается всё снова по-русски. Прежний образец был
    /// украинским целиком, и декодер принимал его за язык всей записи: русское «я сегодня
    /// посмотрел, что там с сервером» возвращалось как «я сьогодні посмотрел, що там з
    /// сервером». Русская рамка это чинит, но украинский кусок обязан остаться связным:
    /// вариант с двумя обрывками в кавычках русскую основу держал, а сами вставки распознавал
    /// хуже прежнего («Хоча требащая подвитись» вместо «Хоча треба ще подвитись», «Дякую, щё
    /// допомих» вместо «Дякую, що допоміг»). Замерено на семи фикстурах 90/10.
    ///
    /// Формулировка нарочно не похожа на рабочую фразу: Whisper склонен доигрывать промпт,
    /// и образец вида «…і зробити коміт.» обрывал настоящую диктовку на этом же месте
    /// (замерено на «…зробити коміт у гілку» — хвост пропадал целиком).
    private static func mixedSample(term: String?) -> String {
        let subject = term ?? "задачи"
        return "Говорим по-русски, но украинские слова остаются украинскими: «треба ще "
            + "перевірити налаштування, а тоді вже з'ясуємо деталі», — и дальше снова "
            + "по-русски про \(subject)."
    }

    private static func punctuationSample(_ language: Language) -> String {
        switch language {
        case .ru: return "Итак, начнём: во-первых, проверим всё — это важно!"
        case .uk: return "Отже, почнімо: по-перше, перевіримо все — це важливо!"
        case .en: return "So, let's start: first of all, we check everything — it matters!"
        }
    }
}
