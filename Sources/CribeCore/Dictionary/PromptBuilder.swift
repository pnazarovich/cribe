import Foundation

/// Слой 1: initial_prompt для Whisper — термины внутри естественных предложений
/// (голый список через запятую провоцирует галлюцинации) + образец пунктуации.
///
/// Промпт русской сессии обязан быть русским целиком. Здесь когда-то жил образец смешанной
/// речи — русская фраза с украинской вставкой внутри, — и на синтезированных фикстурах
/// (`say -v Milena` + `-v Lesya`) он замерялся как рабочий дважды. На настоящей речи владельца
/// он оказался не подсказкой, а переключателем языка: тридцатисекундная русская диктовка
/// возвращалась целиком по-украински («Якщо у нас буде змінюватися ціна закупки…» вместо
/// «Если у нас будет меняться цена закупки…»), и слой 3 такой текст уже не спасал — он его
/// причёсывал. Замер трёх настоящих записей по лесенке «сколько украинских слов в промпте»
/// (0, 2, 4, 8) показал ровно две области: до четырёх слов основа остаётся русской, но ни
/// одного украинского слова в расшифровке не появляется, а на восьми — украинизируется вся
/// запись. Середины, ради которой образец и заводился, нет; см. историю удаления тумблера
/// «Смешанная речь (RU + UK)».
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
        case .en:
            return "We are discussing \(list) and shipping a deploy to production. \(punctuationSample(.en))"
        }
    }

    private static func punctuationSample(_ language: Language) -> String {
        switch language {
        case .ru: return "Итак, начнём: во-первых, проверим всё — это важно!"
        case .uk: return "Отже, почнімо: по-перше, перевіримо все — це важливо!"
        case .en: return "So, let's start: first of all, we check everything — it matters!"
        }
    }
}
