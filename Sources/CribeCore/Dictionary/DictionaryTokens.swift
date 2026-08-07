import Foundation

/// Что словарь уже знает — одним набором слов.
///
/// Нужен в двух местах, и обоим за одним и тем же: не предлагать человеку то, что в словаре
/// и так есть. Накопитель правок этим отсеивает слова, которые словарь заменит сам, а
/// редактор — слова диктовки, добавлять которые уже не нужно.
public enum DictionaryTokens {
    /// Канонические формы, варианты и отдельные слова из них. «pull request» закрывает
    /// и «pull», и «request» — иначе они выглядели бы незнакомыми.
    public static func known(_ entries: [DictionaryEntry]) -> Set<String> {
        var known = Set<String>()
        for entry in entries {
            for phrase in [entry.canonical] + entry.variants {
                let value = phrase.lowercased()
                known.insert(value)
                for word in value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                    known.insert(String(word))
                }
            }
        }
        return known
    }
}
