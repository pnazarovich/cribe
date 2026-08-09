import Foundation

/// Чему словарю стоит научиться из того, что человек сделал с нашим текстом.
///
/// **Зачем судья.** Раньше эту работу делало повторение: пара уезжала в словарь, только
/// когда человек делал ту же правку дважды. Приём честный, но на живой работе почти
/// невыполнимый — за всё время он пропустил в словарь ноль пар, а единственную замеченную
/// («добавлять → gjrть») повторить нельзя даже нарочно. Повторение стояло вместо ума:
/// отличить ошибку распознавания от «человек передумал» правилом нельзя, а моделью — можно.
///
/// **Что судья видит.** Всю картину: вставленный текст, поле сразу после вставки, каждое
/// изменение с его секундой и поле в конце. Сначала ему показывали только пары слов,
/// найденные разбором, — и этого не хватало дважды. Разбор считает лишь замены «слово на
/// слово», а две соседние правки сливаются у него в один блок и не дают ничего; и даже
/// когда пара находится, по ней одной не понять, исправление это или человек начал писать
/// своё. И то и другое видно только в тексте вокруг.
///
/// **Чего судья НЕ решает.** Он не кладёт в словарь: последнее слово за человеком, ему
/// показывают каждую пару отдельно (см. `DictationController.ask`).
public enum DictionaryJudge {

    /// Пара, которую судья предлагает запомнить.
    public struct Proposal: Equatable, Sendable {
        public let heard: String
        public let meant: String
        /// Короткая причина — для журнала.
        public let reason: String

        public init(heard: String, meant: String, reason: String) {
            self.heard = heard
            self.meant = meant
            self.reason = reason
        }
    }

    /// Ждём ответа недолго: правки разбираем в фоне, и застрявший запрос не должен
    /// висеть на приложении дольше самой диктовки.
    public static let timeout: TimeInterval = 12

    public static let systemPrompt = """
        Ты решаешь, чему программе для диктовки стоит научиться из правок человека.

        Программа распознала речь и вставила текст в поле ввода. Дальше она пятнадцать
        секунд смотрела, что человек с этим текстом делает, и записывала каждое изменение
        с его секундой. Ты видишь всё: вставленный текст, поле сразу после вставки, ход
        изменений и поле в конце.

        Найди среди изменений исправления ОШИБОК РАСПОЗНАВАНИЯ — места, где человек заменил
        неверно услышанное слово тем, что он на самом деле сказал. Такие пары уедут в личный
        словарь замен и будут применяться ко ВСЕМ будущим диктовкам.

        Предлагай пару, когда сходится всё сразу:
        - заменено одно слово одним словом;
        - заменённое слово есть во вставленном нами тексте;
        - правильное слово — термин, название, имя собственное, продукт, бренд, аббревиатура
          или иностранное слово, записанное на слух: именно на них распознавание спотыкается
          каждый раз, и словарь заведён ради них.

        Не предлагай пару, когда:
        - человек изменил смысл, стиль или формулировку;
        - правка меняет только грамматическую форму или регистр того же слова;
        - заменённое слово — обычное слово языка без особого написания;
        - человек просто писал дальше поверх нашего текста: дописанные фразы, обрывки,
          набор букв, случайно попавшая в сравнение раскладка.

        Время — довод. Исправление нашего текста человек делает сразу, перечитав вставленное;
        то, что всплыло под конец наблюдения, чаще всего его собственная работа.

        Сомневаешься — не предлагай. Лишняя пара в словаре молча портит все будущие
        диктовки, а пропущенную человек добавит сам.

        Ответ — по строке на каждую пару, без всякого другого текста:
        ДА|услышанное|правильное|краткая причина
        Если предлагать нечего — одна строка: НЕТ|краткая причина.
        """

    /// Что показываем судье: всё, что приложение видело в поле.
    public static func input(_ observation: FieldObservation, language: Language) -> String {
        var parts = [
            "Язык диктовки: \(language.displayName)",
            "Приложение вставило в поле такой текст:\n\(observation.dictated)",
            "Поле сразу после вставки:\n\(observation.baseline)",
            "Что менялось дальше:\n\(timeline(observation.changes))",
            "Поле в конце наблюдения:\n\(observation.final)",
        ]
        if !observation.corrections.isEmpty {
            let list = observation.corrections.map {
                "- «\($0.correction.heard)» → «\($0.correction.meant)» (через \(Int($0.after)) с)"
            }.joined(separator: "\n")
            // Подсказка, а не потолок: разбор видит только замены «слово на слово» и
            // молчит там, где правки идут подряд. Судья вправе предложить и то, чего в
            // этом списке нет.
            parts.append("Разбор нашёл однословные замены (могут быть не все и не все верны):\n\(list)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Ход изменений строками «через N с: что произошло».
    static func timeline(_ changes: [FieldChange]) -> String {
        changes.flatMap { change in
            change.blocks.map { block in
                let moment = "через \(Int(change.after)) с: "
                switch (block.removed.isEmpty, block.added.isEmpty) {
                case (false, false):
                    return moment + "«\(block.removed.joined(separator: " "))» → «\(block.added.joined(separator: " "))»"
                case (true, false):
                    return moment + "добавлено «\(block.added.joined(separator: " "))»"
                default:
                    return moment + "удалено «\(block.removed.joined(separator: " "))»"
                }
            }
        }.joined(separator: "\n")
    }

    /// Разбор ответа. Всё, что не разобралось, — молчание: сбой формата не имеет права
    /// ничего предлагать.
    public static func parse(_ answer: String) -> [Proposal] {
        answer.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, parts[0].uppercased().hasPrefix("ДА") else { return nil }
            guard !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
            return Proposal(heard: parts[1], meant: parts[2], reason: parts.count > 3 ? parts[3] : "")
        }
    }

    /// Оставляет только то, что подтверждается самим текстом.
    ///
    /// Модель вольна в словах, а словарь — нет: придуманная пара молча портила бы каждую
    /// будущую диктовку. Поэтому услышанное обязано быть словом, которое мы и правда
    /// вставили, а правильное — словом, которое человек и правда написал.
    public static func confirmed(_ proposals: [Proposal], in observation: FieldObservation) -> [Correction] {
        let ours = Set(EditDiff.words(in: observation.dictated).map { $0.lowercased() })
        let theirs = Set(EditDiff.words(in: observation.final).map { $0.lowercased() })
        var taken: Set<String> = []
        return proposals.compactMap { proposal in
            let correction = Correction(heard: proposal.heard, meant: proposal.meant)
            guard ours.contains(proposal.heard.lowercased()),
                  theirs.contains(proposal.meant.lowercased()),
                  EditDiff.isPlausible(correction),
                  taken.insert(proposal.heard.lowercased()).inserted
            else { return nil }
            return correction
        }
    }

    /// Спросить модель обо всей картине разом. `nil` — спросить не вышло: сети нет, ключа
    /// нет, ответ не пришёл. Тогда работает прежнее правило с повторением, а не догадка.
    public static func pairs(
        in observation: FieldObservation,
        language: Language,
        config: GPTConfig
    ) async -> [Correction]? {
        guard !observation.changes.isEmpty else { return [] }
        let client = GPTClient(config: config)
        let answer: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await client.respond(
                    instructions: systemPrompt,
                    input: input(observation, language: language)
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
        return confirmed(parse(answer), in: observation)
    }
}
