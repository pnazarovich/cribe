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

    /// Похожа ли пара на исправление распознавания, а не на смену слова по смыслу.
    ///
    /// Проверок немного намеренно. Главная защита здесь не фильтр, а повторение: пара
    /// попадёт в словарь, только если человек сделает ту же правку дважды. Слишком строгий
    /// фильтр отсёк бы ровно то, ради чего всё затевалось: «хероблок» → «heroblock» — это
    /// разные алфавиты и никакой похожести, и по любой мере расстояния такая пара выглядит
    /// как замена слова, а не как исправление.
    private static func isPlausible(_ correction: Correction) -> Bool {
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
    ///
    /// Сначала находим наибольшую общую подпоследовательность — то, что человек не трогал.
    /// Всё между соседними общими словами — это участок правки; засчитываем его, только
    /// если с обеих сторон там ровно по одному слову.
    private static func substitutions(from source: [String], to target: [String]) -> [Correction] {
        var result: [Correction] = []
        var sourceIndex = 0
        var targetIndex = 0

        for anchor in commonAnchors(source, target) + [(source.count, target.count)] {
            let removed = Array(source[sourceIndex..<anchor.0])
            let added = Array(target[targetIndex..<anchor.1])
            if removed.count == 1, added.count == 1 {
                result.append(Correction(heard: removed[0], meant: added[0]))
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
