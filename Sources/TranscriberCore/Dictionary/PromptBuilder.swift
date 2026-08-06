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
            return mixed ? mixedSample(terms: "") : punctuationSample(language)
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
            // Смешанной сессии образец заменяет и хвост рамки, и образец пунктуации: у промпта
            // всего ~64 токена окна, и на три вещи их не хватает (см. `mixedSample`).
            guard !mixed else { return mixedSample(terms: list) }
            return "Мы обсуждаем \(list) и делаем deploy в продакшен. \(punctuationSample(.ru))"
        case .uk:
            return "Ми обговорюємо \(list) і робимо deploy у продакшен. \(punctuationSample(.uk))"
        case .en:
            return "We are discussing \(list) and shipping a deploy to production. \(punctuationSample(.en))"
        }
    }

    /// Промпт смешанной сессии целиком: термины сами служат русской рамкой украинскому куску.
    ///
    /// Устройство — та же пропорция, что у настоящей диктовки: русское начало, внутри один
    /// связный украинский кусок, и кончается всё снова по-русски (внимание Whisper смещено
    /// к хвосту, и последнее слово промпта задаёт тон первому слову речи). Прежний образец был
    /// украинским целиком, и декодер принимал его за язык всей записи: русское «я сегодня
    /// посмотрел, что там с сервером» возвращалось как «я сьогодні посмотрел, що там з
    /// сервером». Украинский кусок обязан остаться связным: короткий («треба ще перевірити
    /// налаштування») основу держит, а вставки распознаёт хуже — «душе прикро» вместо «дуже
    /// прикро», «Дякую, шчё допомих» вместо «Дякую, що допоміг». Замерено на 12 фикстурах 90/10.
    ///
    /// Роль русской рамки играют сами термины, и это не экономия ради экономии: у промпта
    /// 64 токена окна (см. `WhisperEngine.maxPromptTokens`), сам образец стоит 47, и на
    /// отдельное объяснение «но украинские слова остаются украинскими» (ещё 14 токенов) места
    /// не остаётся — с ним из словаря не доезжало ни одного термина, без него доезжает шесть.
    /// И они работают: «заапрувить ТЗ … ClinicCards» против «заопровить ТЗ … Clinic Cards» на
    /// одной и той же записи. На качество вставок объяснение при этом не влияло — 11 фикстур
    /// из 12 совпали слово в слово.
    ///
    /// Формулировка нарочно не похожа на рабочую фразу: Whisper склонен доигрывать промпт,
    /// и образец вида «…і зробити коміт.» обрывал настоящую диктовку на этом же месте
    /// (замерено на «…зробити коміт у гілку» — хвост пропадал целиком).
    private static func mixedSample(terms: String) -> String {
        let head = terms.isEmpty ? "Говорим по-русски" : "Говорим по-русски про \(terms)"
        return head + ": «треба ще перевірити налаштування, а тоді вже з'ясуємо деталі», "
            + "— и дальше снова по-русски."
    }

    private static func punctuationSample(_ language: Language) -> String {
        switch language {
        case .ru: return "Итак, начнём: во-первых, проверим всё — это важно!"
        case .uk: return "Отже, почнімо: по-перше, перевіримо все — це важливо!"
        case .en: return "So, let's start: first of all, we check everything — it matters!"
        }
    }
}
