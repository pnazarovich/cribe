import Foundation

/// Слой 2: детерминированные замены транслитерации на канонические термины.
/// Чистая функция, работает всегда и локально — гарантирующий слой конвейера.
public enum ReplacementEngine {
    public static func apply(_ text: String, entries: [DictionaryEntry]) -> String {
        var result = text
        for rule in rules(for: entries) {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    /// Минимальная длина основы, при которой можно отбрасывать конечную -й/-ь/-ъ.
    /// Короткая основа ловит посторонние слова: «стал» из «сталь» съел бы «сталкер».
    private static let minimumStemLength = 5

    /// Длинные варианты идут первыми: «гит хаб» должен сработать раньше «гит».
    /// При равной длине — алфавитный tie-break: `sorted` не стабилен, а порядок правил
    /// влияет на результат, поэтому он должен быть детерминированным.
    private static func rules(for entries: [DictionaryEntry]) -> [Rule] {
        var pairs: [(variant: String, entry: DictionaryEntry)] = []
        for entry in entries {
            for variant in entry.variants where !variant.trimmingCharacters(in: .whitespaces).isEmpty {
                pairs.append((variant: variant, entry: entry))
            }
        }
        pairs.sort { lhs, rhs in
            if lhs.variant.count != rhs.variant.count {
                return lhs.variant.count > rhs.variant.count
            }
            return lhs.variant < rhs.variant
        }
        return pairs.compactMap { pair in
            let pattern = pattern(for: pair.variant, stem: pair.entry.stem)
            let options: NSRegularExpression.Options = [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return nil
            }
            let template = NSRegularExpression.escapedTemplate(for: pair.entry.canonical)
            return Rule(regex: regex, template: template)
        }
    }

    private static func pattern(for variant: String, stem: Bool) -> String {
        // Вариант из нескольких слов: пробелы → \s+.
        var words = variant.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        // Слова на -й/-ь/-ъ склоняются заменой этой буквы («деплой» → «деплоя»),
        // поэтому у stem-вариантов она необязательна — но только если оставшаяся
        // основа достаточно длинная, иначе паттерн ловит посторонние слова.
        if stem, let last = words.last, let tail = last.last, "йьъЙЬЪ".contains(tail) {
            let base = String(last.dropLast())
            if base.count >= minimumStemLength {
                words[words.count - 1] = base + "\(tail)?"
            }
        }
        let core = words.joined(separator: "\\s+")
        // Границы слова по буквам/цифрам: «загитхабить» не начинается с триггера — не матчится.
        return "(?<![\\p{L}\\p{N}])(?:\(core))\(stem ? "[\\p{L}]*" : "")(?![\\p{L}\\p{N}])"
    }
}
