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

        Правки пронумерованы и даны со временем появления. Время — довод: исправление
        нашего текста человек делает сразу, перечитав вставленное, а то, что всплыло
        под конец наблюдения, чаще всего обрывок его собственной работы поверх текста.

        Ответь по строке на каждую правку, в том же порядке и с тем же номером:
        НОМЕР|ДА|краткая причина или НОМЕР|НЕТ|краткая причина.
        Никакого другого текста.
        """
    }

    /// Что показываем судье: продиктованная фраза и все пары, найденные за окно
    /// наблюдения, с временем появления. Пары нумерованы — по номерам и приходит ответ.
    public static func input(_ found: [ObservedCorrection], sentence: String) -> String {
        let list = found.enumerated().map { index, item in
            "\(index + 1). «\(item.correction.heard)» → «\(item.correction.meant)» "
                + "(через \(Int(item.after)) с)"
        }.joined(separator: "\n")
        return """
        Продиктованный текст: \(sentence)

        Замеченные правки:
        \(list)
        """
    }

    /// Разбор ответа: по вердикту на каждую правку, в том же порядке.
    ///
    /// Всё, что не разобралось, — отказ. Сбой формата не имеет права пополнять словарь:
    /// лишняя пара молча портит ВСЕ будущие диктовки, а пропущенную человек добавит сам.
    /// Поэтому длина ответа заранее известна — по числу правок, — и недостающие строки
    /// становятся отказами, а лишние отбрасываются.
    public static func parse(_ answer: String, count: Int) -> [Verdict] {
        var verdicts = Array(
            repeating: Verdict(learn: false, reason: "ответ не разобран"),
            count: count
        )
        for line in answer.split(separator: "\n") {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let number = Int(parts[0]), (1...count).contains(number) else {
                continue
            }
            let reason = parts.count > 2 ? parts[2] : ""
            verdicts[number - 1] = Verdict(learn: parts[1].uppercased().hasPrefix("ДА"), reason: reason)
        }
        return verdicts
    }

    /// Спросить модель обо всей пачке разом. `nil` — спросить не вышло: сети нет, ключа
    /// нет, ответ не пришёл. Тогда работает прежнее правило с повторением, а не догадка.
    public static func verdicts(
        on found: [ObservedCorrection],
        sentence: String,
        language: Language,
        config: GPTConfig
    ) async -> [Verdict]? {
        guard !found.isEmpty else { return [] }
        let client = GPTClient(config: config)
        let answer: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await client.respond(
                    instructions: systemPrompt(language: language),
                    input: input(found, sentence: sentence)
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
        return parse(answer, count: found.count)
    }
}
