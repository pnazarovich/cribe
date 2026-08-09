import Foundation

/// Одна замеченная правка: слово, которое вставило приложение, и слово, которым его
/// заменил человек. Это и есть будущая пара «вариант → каноническая форма» словаря.
public struct Correction: Hashable, Sendable {
    /// Что услышалось и попало в поле.
    public let heard: String
    /// На что человек это исправил.
    public let meant: String

    public init(heard: String, meant: String) {
        self.heard = heard
        self.meant = meant
    }
}

/// О чём спрашивают человека: что уедет в словарь и что он при этом видел своими глазами.
///
/// Два слова здесь не для красоты. В словарь едет слово РАСПОЗНАВАНИЯ, а правил человек
/// то, что осталось после причёсывания, — и это бывают разные слова. Спросить про «клайв»
/// у того, кто исправлял «scribe», значит спросить про слово, которого он никогда не видел:
/// на такой вопрос нельзя ответить осмысленно, и доверия к приложению он не прибавляет.
public struct LearnRequest: Hashable, Sendable {
    /// Пара, которая уедет в словарь.
    public let correction: Correction
    /// Слово из вставленного текста — то, что человек правил. `nil`, когда оно совпадает
    /// с услышанным: тогда и объяснять нечего.
    public let edited: String?

    public init(correction: Correction, edited: String? = nil) {
        self.correction = correction
        self.edited = edited
    }
}

/// Правка вместе с тем, когда она появилась.
///
/// Время — не отчётность, а довод. Исправление нашего текста человек делает сразу,
/// перечитав вставленное; всё, что всплывает под конец наблюдения, — это уже он сам пишет
/// поверх, и такая «правка» на деле обрывок его работы. Судья видит секунды и судит с ними.
public struct ObservedCorrection: Hashable, Sendable {
    public let correction: Correction
    /// Через сколько секунд после вставки пара впервые появилась в поле.
    public let after: TimeInterval

    public init(correction: Correction, after: TimeInterval) {
        self.correction = correction
        self.after = after
    }
}

/// Один участок расхождения между двумя состояниями поля: что исчезло и что появилось.
///
/// В отличие от `Correction`, блок не ограничен заменой «слово на слово»: он описывает
/// ровно то, что видно в тексте, включая дописанные фразы и удалённые куски. Судья
/// (`DictionaryJudge`) разбирается в этом лучше любого правила — ему блоки и показываем.
public struct EditBlock: Hashable, Sendable {
    /// Слова, которых в новом состоянии больше нет. Пусто — человек просто дописал.
    public let removed: [String]
    /// Слова, появившиеся на их месте. Пусто — человек удалил.
    public let added: [String]

    public init(removed: [String], added: [String]) {
        self.removed = removed
        self.added = added
    }
}

/// Что произошло в поле за один такт наблюдения.
public struct FieldChange: Hashable, Sendable {
    /// Секунда от вставки, на которой такт случился.
    public let after: TimeInterval
    public let blocks: [EditBlock]

    public init(after: TimeInterval, blocks: [EditBlock]) {
        self.after = after
        self.blocks = blocks
    }
}

/// Всё, что приложение увидело в поле за окно наблюдения.
///
/// Раньше наружу уходили только пары слов, найденные разбором. Этого мало по двум причинам
/// сразу. Первая: разбор считает лишь замены «слово на слово», а две соседние правки
/// сливаются у него в один блок из двух слов и не дают НИЧЕГО — настоящее исправление
/// при этом теряется. Вторая: по голой паре нельзя понять, исправление это или человек
/// начал писать своё, — для этого нужен текст вокруг.
///
/// Поэтому наружу уходит вся картина: что мы вставили, каким поле было сразу после вставки,
/// что менялось и на каких секундах, каким поле стало в конце.
public struct FieldObservation: Hashable, Sendable {
    /// Текст, который вставило приложение.
    public let dictated: String
    /// Что услышало распознавание — до того, как текст причесал GPT.
    ///
    /// Ради этой строки всё и затевается. Словарь применяется к тексту распознавания,
    /// а не к тому, что вставлено: пара «то, что услышалось» → «как правильно» срабатывает
    /// ДО GPT. Учить же по вставленному тексту значит учить слову GPT — а его в
    /// распознанном тексте не будет никогда. Живой случай: Whisper услышал «клайв», GPT
    /// причесал это в «scribe», человек исправил на «Cribe». Пара «scribe → Cribe» не
    /// сработает ни разу; работает «клайв → Cribe».
    public let recognized: String
    /// Всё содержимое поля сразу после вставки.
    public let baseline: String
    /// Всё содержимое поля в конце наблюдения.
    public let final: String
    /// Изменения по тактам, в порядке появления.
    public let changes: [FieldChange]
    /// Однословные замены, которые нашёл разбор. Не потолок для судьи, а подсказка ему —
    /// и запасной путь на случай, когда судьи нет.
    public let corrections: [ObservedCorrection]

    public init(
        dictated: String,
        recognized: String,
        baseline: String,
        final: String,
        changes: [FieldChange],
        corrections: [ObservedCorrection]
    ) {
        self.dictated = dictated
        self.recognized = recognized
        self.baseline = baseline
        self.final = final
        self.changes = changes
        self.corrections = corrections
    }
}

/// Что человек поправил в уже вставленном тексте.
///
/// Приём тот же, что у Whispr Flow: приложение помнит, что вставило, а потом смотрит, во
/// что это превратилось. Правки человека — единственный честный источник словаря: он не
/// угадывает термины по виду слова, а видит, что распозналось не так, — включая слова,
/// которых никакая эвристика не поймает.
///
/// Считаются **только замены одного слова одним словом**. Всё остальное — переписанная
/// фраза, вставленное предложение, удалённый абзац — это человек передумал, а не
/// приложение ослышалось. Отличить одно от другого нельзя, поэтому берём лишь тот случай,
/// где ошибка распознавания выглядит однозначно.
public enum EditDiff {
    /// Потолок длины текста, который сравниваем. Сравнение квадратично по числу слов, а
    /// диктуют иногда в большой документ: без потолка одна правка в конце статьи заняла бы
    /// секунды и мегабайты. Восемьсот слов — это несколько абзацев, то есть заведомо больше
    /// любой диктовки; всё, что длиннее, просто пропускаем.
    static let maximumWords = 800

    /// Правки между состоянием поля сразу после вставки и его состоянием потом.
    ///
    /// - Parameters:
    ///   - before: всё содержимое поля сразу после вставки.
    ///   - after: всё содержимое того же поля позже.
    ///   - inserted: что именно вставило приложение. Нужен, чтобы не считать своими
    ///     правки в чужом тексте, который был в поле до нас.
    public static func corrections(before: String, after: String, inserted: String) -> [Correction] {
        let source = words(in: before)
        let target = words(in: after)
        guard !source.isEmpty, !target.isEmpty,
              source.count <= maximumWords, target.count <= maximumWords else { return [] }

        let ours = Set(words(in: inserted).map { $0.lowercased() })
        guard !ours.isEmpty else { return [] }

        return substitutions(from: source, to: target)
            // Правка в тексте, которого мы не вставляли, — не наше дело.
            .filter { ours.contains($0.heard.lowercased()) }
            .filter { isPlausible($0) }
    }

    /// Все участки, где текст разошёлся, — без требования «слово на слово».
    ///
    /// Это то, что видит судья: правило отсекает слишком много, а показать изменение
    /// как есть ничего не стоит.
    public static func changes(before: String, after: String) -> [EditBlock] {
        let source = words(in: before)
        let target = words(in: after)
        guard source.count <= maximumWords, target.count <= maximumWords else { return [] }
        return blocks(from: source, to: target)
    }

    /// Похожа ли пара на исправление распознавания, а не на смену слова по смыслу.
    ///
    /// Проверок немного намеренно. Главная защита здесь не фильтр, а повторение: пара
    /// попадёт в словарь, только если человек сделает ту же правку дважды. Слишком строгий
    /// фильтр отсёк бы ровно то, ради чего всё затевалось: «хероблок» → «heroblock» — это
    /// разные алфавиты и никакой похожести, и по любой мере расстояния такая пара выглядит
    /// как замена слова, а не как исправление.
    static func isPlausible(_ correction: Correction) -> Bool {
        // Смена регистра — это не термин: «привет» → «Привет» приложение вставило верно.
        guard correction.heard.lowercased() != correction.meant.lowercased() else { return false }
        // Однобуквенные — опечатки и инициалы, а не словарные термины.
        guard correction.heard.count >= 2, correction.meant.count >= 2 else { return false }
        // Услышанное обязано быть словом: цифры и коды приложение не «слышит» неверно так,
        // чтобы это стоило запоминать.
        return correction.heard.allSatisfy(\.isLetter)
    }

    /// Слова текста в порядке следования. Разделитель — всё, что не буква и не цифра:
    /// знаки препинания человек правит постоянно, и к словарю это отношения не имеет.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Замены «одно слово → одно слово» между двумя последовательностями.
    private static func substitutions(from source: [String], to target: [String]) -> [Correction] {
        blocks(from: source, to: target).compactMap { block in
            guard block.removed.count == 1, block.added.count == 1 else { return nil }
            return Correction(heard: block.removed[0], meant: block.added[0])
        }
    }

    /// Участки расхождения между двумя последовательностями слов.
    ///
    /// Сначала находим наибольшую общую подпоследовательность — то, что человек не трогал.
    /// Всё между соседними общими словами и есть участок правки.
    private static func blocks(from source: [String], to target: [String]) -> [EditBlock] {
        var result: [EditBlock] = []
        var sourceIndex = 0
        var targetIndex = 0

        for anchor in commonAnchors(source, target) + [(source.count, target.count)] {
            let removed = Array(source[sourceIndex..<anchor.0])
            let added = Array(target[targetIndex..<anchor.1])
            if !removed.isEmpty || !added.isEmpty {
                result.append(EditBlock(removed: removed, added: added))
            }
            sourceIndex = anchor.0 + 1
            targetIndex = anchor.1 + 1
        }
        return result
    }

    /// Пары индексов совпавших слов — наибольшая общая подпоследовательность.
    /// Сравнение без учёта регистра: заглавная буква в начале предложения не должна
    /// выглядеть правкой и разрывать выравнивание.
    private static func commonAnchors(_ source: [String], _ target: [String]) -> [(Int, Int)] {
        let left = source.map { $0.lowercased() }
        let right = target.map { $0.lowercased() }
        var lengths = Array(
            repeating: Array(repeating: Int32(0), count: right.count + 1),
            count: left.count + 1
        )
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                lengths[i][j] = left[i] == right[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var anchors: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                anchors.append((i, j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return anchors
    }
}
