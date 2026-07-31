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

    /// Длинные варианты идут первыми: «гит хаб» должен сработать раньше «гит».
    private static func rules(for entries: [DictionaryEntry]) -> [Rule] {
        entries
            .flatMap { entry in entry.variants.map { (variant: $0, entry: entry) } }
            .filter { !$0.variant.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.variant.count > $1.variant.count }
            .compactMap { pair in
                let pattern = pattern(for: pair.variant, stem: pair.entry.stem)
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return nil
                }
                return Rule(regex: regex, template: NSRegularExpression.escapedTemplate(for: pair.entry.canonical))
            }
    }

    private static func pattern(for variant: String, stem: Bool) -> String {
        // Вариант из нескольких слов: пробелы → \s+.
        var words = variant.split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        // Слова на -й/-ь/-ъ склоняются заменой этой буквы («деплой» → «деплоя»),
        // поэтому у stem-вариантов она необязательна.
        if stem, let last = words.last, let tail = last.last, "йьъЙЬЪ".contains(tail) {
            words[words.count - 1] = String(last.dropLast()) + "\(tail)?"
        }
        let core = words.joined(separator: "\\s+")
        // Границы слова по буквам/цифрам: «загитхабить» не начинается с триггера — не матчится.
        return "(?<![\\p{L}\\p{N}])(?:\(core))\(stem ? "[\\p{L}]*" : "")(?![\\p{L}\\p{N}])"
    }
}
