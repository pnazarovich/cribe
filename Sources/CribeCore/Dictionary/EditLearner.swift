import Combine
import Foundation

/// Правка, замеченная в поле ввода, и сколько раз человек её повторил.
public struct LearnedCorrection: Identifiable, Equatable, Sendable {
    public let correction: Correction
    public let count: Int

    public var id: String { "\(correction.heard)→\(correction.meant)" }

    public init(correction: Correction, count: Int) {
        self.correction = correction
        self.count = count
    }
}

/// Словарь, который учится на правках человека.
///
/// Заменяет прежние «Предложения». Те угадывали термины по виду слова — латиница посреди
/// кириллицы, длинное некороткое слово, — и ошибались в обе стороны сразу: тащили в список
/// случайные слова и не видели ровно тех, ради которых словарь и нужен. Здесь источник
/// другой и честный: что человек исправил руками, то и есть ошибка распознавания.
///
/// Молча в словарь попадает только **повторённая** правка. Один раз человек мог исправить
/// что угодно и по любой причине; та же самая правка во второй раз — это уже про то, как
/// он говорит, а не про то, что он передумал.
public final class EditLearner: ObservableObject {
    /// Сколько раз должна повториться одна и та же правка, чтобы уехать в словарь.
    public static let threshold = 2

    /// Дальше счётчики не растут: это короткая память, а не архив правок.
    private static let maximumTracked = 300

    private enum Key {
        static let counts = "editCorrectionCounts"
        static let ignored = "editCorrectionIgnored"
    }

    private let defaults: UserDefaults
    private var counts: [String: Int]
    private var ignored: Set<String>

    /// Правки, замеченные по одному разу: до словаря им ещё далеко, но человеку их видно.
    @Published public private(set) var pending: [LearnedCorrection] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        counts = defaults.dictionary(forKey: Key.counts) as? [String: Int] ?? [:]
        ignored = Set(defaults.stringArray(forKey: Key.ignored) ?? [])
        pending = Self.pending(counts: counts)
    }

    // MARK: - Наблюдение

    /// Принять правки одной диктовки и сказать, что из них пора класть в словарь.
    ///
    /// Возвращает готовые статьи, а не пишет в словарь сам: у словаря один хозяин, и
    /// счётчику правок им быть незачем.
    @discardableResult
    public func observe(_ corrections: [Correction], entries: [DictionaryEntry]) -> [DictionaryEntry] {
        let known = DictionaryTokens.known(entries)
        var learned: [DictionaryEntry] = []

        for correction in corrections {
            let key = Self.key(correction)
            guard !ignored.contains(key) else { continue }
            // Слово уже в словаре как вариант: значит, замена и так произойдёт сама,
            // а правка была про что-то другое.
            guard !known.contains(correction.heard.lowercased()) else { continue }

            counts[key, default: 0] += 1
            guard counts[key] ?? 0 >= Self.threshold else { continue }

            counts[key] = nil
            learned.append(Self.entry(for: correction, entries: entries))
        }

        prune()
        save()
        pending = Self.pending(counts: counts)
        return learned
    }

    /// Правку отвергли: больше её не считаем и в словарь не тащим.
    public func ignore(_ correction: Correction) {
        let key = Self.key(correction)
        counts[key] = nil
        ignored.insert(key)
        save()
        pending = Self.pending(counts: counts)
    }

    /// Правку приняли досрочно, не дожидаясь повтора.
    public func accept(_ correction: Correction, entries: [DictionaryEntry]) -> DictionaryEntry {
        counts[Self.key(correction)] = nil
        save()
        pending = Self.pending(counts: counts)
        return Self.entry(for: correction, entries: entries)
    }

    // MARK: - Внутреннее

    private func save() {
        defaults.set(counts, forKey: Key.counts)
        defaults.set(Array(ignored).sorted(), forKey: Key.ignored)
    }

    private func prune() {
        guard counts.count > Self.maximumTracked else { return }
        // Выкидываем одиночные: до порога им дальше всех, а места они занимают больше всех.
        counts = counts.filter { $0.value >= Self.threshold }
    }

    static func key(_ correction: Correction) -> String {
        "\(correction.heard.lowercased())→\(correction.meant)"
    }

    static func correction(fromKey key: String) -> Correction? {
        let parts = key.components(separatedBy: "→")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return Correction(heard: parts[0], meant: parts[1])
    }

    /// Статья словаря из правки. Если каноническая форма уже есть, вариант дописывается
    /// к ней — иначе в словаре завелись бы две статьи про одно и то же слово.
    static func entry(for correction: Correction, entries: [DictionaryEntry]) -> DictionaryEntry {
        let variant = correction.heard.lowercased()
        if var existing = entries.first(where: { $0.canonical.lowercased() == correction.meant.lowercased() }) {
            if !existing.variants.contains(where: { $0.lowercased() == variant }) {
                existing.variants.append(variant)
            }
            return existing
        }
        return DictionaryEntry(canonical: correction.meant, variants: [variant])
    }

    static func pending(counts: [String: Int]) -> [LearnedCorrection] {
        counts
            .compactMap { key, count in
                correction(fromKey: key).map { LearnedCorrection(correction: $0, count: count) }
            }
            // Порядок обязан быть устойчивым, иначе список перетасовывается на каждой правке.
            .sorted {
                $0.count == $1.count ? $0.id < $1.id : $0.count > $1.count
            }
    }
}

extension EditLearner {
    /// Общий накопитель приложения. Отдельные экземпляры существуют ради тестов.
    public static let shared = EditLearner()
}
