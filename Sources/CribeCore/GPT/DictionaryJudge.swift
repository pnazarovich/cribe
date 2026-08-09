import Foundation

/// Стоит ли класть замеченную правку в словарь.
///
/// **Зачем судья.** Раньше эту работу делало повторение: пара уезжала в словарь, только
/// когда человек делал ту же правку дважды. Приём честный, но на живой работе почти
/// невыполнимый — за всё время он пропустил в словарь ноль пар, а единственную замеченную
/// («добавлять → gjrть») повторить нельзя даже нарочно. Повторение стояло вместо ума:
/// отличить ошибку распознавания от «человек передумал» правилом нельзя, а моделью — можно.
///
/// **Чего судья НЕ решает.** Он не выбирает каноническую форму и не придумывает вариантов:
/// и то и другое уже есть в самой правке. Его вопрос ровно один — запоминать или нет.
public enum DictionaryJudge {

    /// Ответ судьи. `nil` вместо ответа означает «спросить не удалось» — и тогда работает
    /// прежнее правило с повторением, а не догадка.
    public struct Verdict: Equatable, Sendable {
        public let learn: Bool
        /// Короткая причина — для журнала. Человеку её не показываем: он видит результат.
        public let reason: String

        public init(learn: Bool, reason: String) {
            self.learn = learn
            self.reason = reason
        }
    }

    /// Ждём ответа недолго: правку разбираем в фоне, и застрявший запрос не должен
    /// висеть на приложении дольше самой диктовки.
    public static let timeout: TimeInterval = 8

    public static func systemPrompt(language: Language) -> String {
        """
        Ты решаешь, стоит ли добавить пару в личный словарь замен программы для диктовки.

        Программа распознала речь, человек исправил ОДНО слово руками. Твоя задача — понять,
        это ошибка распознавания, которая повторится, или разовая правка.

        Отвечай ДА, когда исправленное слово — термин, название, имя собственное, продукт,
        бренд, аббревиатура или иностранное слово, записанное кириллицей на слух. Такие
        ошибки повторяются на каждой диктовке, и словарь для них и заведён.

        Отвечай НЕТ во всех остальных случаях, а именно:
        - человек изменил смысл, стиль или формулировку;
        - правка меняет только грамматическую форму того же слова;
        - исправленное слово — обычное слово языка без особого написания;
        - «исправление» выглядит бессмыслицей, обрывком или набором букв (человек просто
          печатал дальше поверх нашего текста, и это попало в сравнение).

        Сомневаешься — отвечай НЕТ. Лишняя пара в словаре молча портит все будущие диктовки,
        а пропущенную человек добавит сам.

        Формат ответа — одна строка: ДА|краткая причина или НЕТ|краткая причина.
        Никакого другого текста.
        """
    }

    /// Что показываем судье: сама пара и фраза, в которой она стояла.
    public static func input(heard: String, meant: String, sentence: String) -> String {
        """
        Распознано: \(heard)
        Исправлено на: \(meant)
        Фраза целиком: \(sentence)
        """
    }

    /// Разбор ответа. Всё, что не начинается с «ДА», — отказ: неразобранный ответ обязан
    /// значить «не добавлять», иначе сбой формата пополнял бы словарь мусором.
    public static func parse(_ answer: String) -> Verdict {
        let line = answer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) ?? ""
        let parts = line.split(separator: "|", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let head = (parts.first ?? "").uppercased()
        let reason = parts.count > 1 ? parts[1] : line
        return Verdict(learn: head.hasPrefix("ДА"), reason: reason)
    }

    /// Спросить модель. `nil` — спросить не вышло: сети нет, ключа нет, ответ не пришёл.
    public static func verdict(
        heard: String,
        meant: String,
        sentence: String,
        language: Language,
        config: GPTConfig
    ) async -> Verdict? {
        let client = GPTClient(config: config)
        let answer: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await client.respond(
                    instructions: systemPrompt(language: language),
                    input: input(heard: heard, meant: meant, sentence: sentence)
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return parse(answer)
    }
}
