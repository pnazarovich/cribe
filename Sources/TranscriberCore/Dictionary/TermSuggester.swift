import Combine
import Foundation

/// Слово-кандидат в словарь и число диктовок, в которых оно встретилось.
public struct TermCandidate: Identifiable, Equatable, Sendable {
    public let token: String
    public let count: Int

    public var id: String { token }

    public init(token: String, count: Int) {
        self.token = token
        self.count = count
    }
}

/// Подсказки терминов: после каждой диктовки сканирует финальный текст и копит слова,
/// похожие на жаргон, которого в словаре ещё нет.
///
/// Ничего не показывает и никого не перебивает: это счётчики в UserDefaults, из которых
/// UI сам решает, когда и как о них сказать. Во время диктовки — никогда.
public final class TermSuggester: ObservableObject {
    public static let shared = TermSuggester()

    /// Сколько РАЗНЫХ диктовок должны содержать слово, чтобы предлагать его в словарь.
    /// Одна случайная — это ещё не термин; две — уже привычка речи.
    public static let threshold = 2

    /// Латинское слово короче — это `ok`, `id`, `pr`: шум, а не термин.
    private static let minimumLatinLength = 3
    /// Кириллическое короче — почти всегда служебное слово, которого нет в стоп-листе.
    private static let minimumCyrillicLength = 4
    /// Дальше счётчики не растут: словарь кандидатов не архив, а короткая память.
    private static let maximumTrackedTokens = 300

    private enum Key {
        static let counts = "termCandidateCounts"
        static let ignored = "termCandidateIgnored"
    }

    private let defaults: UserDefaults

    /// Кандидаты, перешагнувшие порог; самые частые первыми.
    @Published public private(set) var suggestions: [TermCandidate] = []

    private var counts: [String: Int]
    private var ignored: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        counts = defaults.dictionary(forKey: Key.counts) as? [String: Int] ?? [:]
        ignored = Set(defaults.stringArray(forKey: Key.ignored) ?? [])
        suggestions = Self.suggestions(counts: counts, ignored: ignored, known: [])
    }

    // MARK: - Наблюдение

    /// Финальный текст одной диктовки: каждое слово-кандидат считается один раз,
    /// сколько бы раз оно в этой диктовке ни повторилось.
    public func observe(_ text: String, entries: [DictionaryEntry]) {
        let known = Self.knownTokens(entries)
        let found = Self.candidates(in: text, known: known)
        for token in found where !ignored.contains(token) {
            counts[token, default: 0] += 1
        }
        prune()
        defaults.set(counts, forKey: Key.counts)
        suggestions = Self.suggestions(counts: counts, ignored: ignored, known: known)
    }

    /// Пересчёт под текущий словарь: термин мог попасть в словарь мимо подсказок,
    /// и предлагать его второй раз незачем.
    public func refresh(entries: [DictionaryEntry]) {
        suggestions = Self.suggestions(counts: counts, ignored: ignored, known: Self.knownTokens(entries))
    }

    /// Подсказку приняли — слово уехало в словарь, счётчик больше не нужен.
    public func accept(_ token: String, entries: [DictionaryEntry]) {
        counts[token] = nil
        defaults.set(counts, forKey: Key.counts)
        refresh(entries: entries)
    }

    /// Подсказку отклонили: слово в словарь не просится и предлагаться больше не должно.
    public func ignore(_ token: String, entries: [DictionaryEntry]) {
        counts[token] = nil
        ignored.insert(token)
        defaults.set(counts, forKey: Key.counts)
        defaults.set(Array(ignored).sorted(), forKey: Key.ignored)
        refresh(entries: entries)
    }

    /// Счётчиков стало слишком много — выкидываем одиночные встречи: до порога им далеко,
    /// а места они занимают больше всех.
    private func prune() {
        guard counts.count > Self.maximumTrackedTokens else { return }
        counts = counts.filter { $0.value >= Self.threshold }
    }

    // MARK: - Чистая логика

    /// Всё, что словарь уже знает: канонические формы, варианты и отдельные слова из них.
    /// «pull request» закрывает и «pull», и «request» — иначе они полезут в подсказки.
    /// Публично: тем же набором редактор отсеивает слова диктовки, которые предлагать нечего.
    public static func knownTokens(_ entries: [DictionaryEntry]) -> Set<String> {
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

    /// Слова-кандидаты одной диктовки. Текст берётся ФИНАЛЬНЫЙ: всё, что словарь умел
    /// заменить, здесь уже стоит канонической формой и в кандидаты не попадёт.
    static func candidates(in text: String, known: Set<String>) -> Set<String> {
        var found = Set<String>()
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(word)
            guard !known.contains(token), looksLikeTerm(token) else { continue }
            found.insert(token)
        }
        return found
    }

    /// Похоже ли слово на термин: латиница в русской речи — почти всегда он,
    /// кириллица — только если это не ходовое слово языка.
    static func looksLikeTerm(_ token: String) -> Bool {
        guard token.allSatisfy(\.isLetter) else { return false }
        if token.allSatisfy(\.isLatinLetterToken) {
            return token.count >= minimumLatinLength
        }
        guard token.allSatisfy(\.isCyrillicLetter) else { return false }
        return token.count >= minimumCyrillicLength && !stopWords.contains(token)
    }

    static func suggestions(
        counts: [String: Int],
        ignored: Set<String>,
        known: Set<String>
    ) -> [TermCandidate] {
        counts
            .filter { $0.value >= threshold && !ignored.contains($0.key) && !known.contains($0.key) }
            .map { TermCandidate(token: $0.key, count: $0.value) }
            // Частые первыми, при равенстве — по алфавиту: порядок обязан быть устойчивым,
            // иначе список подсказок перетасовывается на каждом обновлении.
            .sorted { $0.count == $1.count ? $0.token < $1.token : $0.count > $1.count }
    }
}

// MARK: - Стоп-лист

extension TermSuggester {
    /// Ходовые слова русского и украинского. Полного словаря языка тут не нужно: задача
    /// списка — отсечь речевой фон, а не доказать, что слово существует. Всё, что длиннее
    /// трёх букв, не служебное и повторяется от диктовки к диктовке, — уже кандидат.
    static let stopWords: Set<String> = [
        // Русский: служебные и самые частые.
        "быть", "весь", "если", "меня", "тебя", "себя", "него", "неё", "нему",
        "этот", "этом", "этой", "эти", "того", "тому", "тем", "теми", "который", "которая",
        "которые", "которых", "чтобы", "потому", "поэтому", "когда", "тогда", "теперь",
        "сейчас", "сегодня", "вчера", "завтра", "здесь", "там", "тут", "туда", "сюда",
        "везде", "очень", "просто", "только", "ещё", "уже", "почти", "снова", "опять",
        "тоже", "также", "даже", "лишь", "ведь", "надо", "нужно", "можно", "нельзя",
        "давай", "давайте", "ладно", "хорошо", "плохо", "конечно", "наверное", "может",
        "должен", "должна", "должно", "хочу", "хочет", "хотел", "хотела", "будет", "будут",
        "было", "была", "были", "есть", "нет", "да", "как", "что", "кто", "где", "куда",
        "зачем", "почему", "сколько", "какой", "какая", "какие", "такой", "такая", "такие",
        "один", "одна", "одно", "два", "две", "три", "четыре", "пять", "шесть", "семь",
        "восемь", "девять", "десять", "первый", "второй", "третий", "много", "мало",
        "больше", "меньше", "лучше", "хуже", "самый", "самое", "самая", "сам", "сама",
        "мой", "моя", "моё", "мои", "твой", "твоя", "наш", "наша", "ваш", "ваша", "свой",
        "своя", "своё", "свои", "нас", "вас", "них", "ним", "ней",
        "делать", "сделать", "сделай", "сделал", "делаю", "делает", "говорить", "сказать",
        "сказал", "скажи", "знаю", "знает", "знать", "думаю", "думает", "думать", "видеть",
        "вижу", "смотри", "смотреть", "идти", "пойти", "пошли", "стало", "стал", "стать",
        "время", "года", "году", "день", "дня", "неделя", "месяц", "минут", "минуты",
        "часа", "часов", "работа", "работу", "работы", "работать", "дело", "дела", "вопрос",
        "вопросы", "ответ", "человек", "люди", "жизнь", "место", "места", "сторона",
        "слово", "слова", "текст", "пример", "случай", "часть", "конец", "начало",
        "спасибо", "пожалуйста", "привет", "пока", "значит", "например", "кстати",
        "вообще", "просто", "нормально", "точно", "правда", "конечно", "хотя",
        // Украинский: то же самое.
        "бути", "весь", "якщо", "мене", "тебе", "себе", "нього", "неї", "ньому",
        "цей", "цьому", "цієї", "цих", "того", "тому", "тим", "який", "яка", "які",
        "яких", "щоб", "тому", "коли", "тоді", "тепер", "зараз", "сьогодні", "вчора",
        "завтра", "тут", "там", "туди", "сюди", "скрізь", "дуже", "просто", "тільки",
        "ще", "вже", "майже", "знову", "теж", "також", "навіть", "лише", "адже",
        "треба", "потрібно", "можна", "давай", "давайте", "гаразд", "добре",
        "погано", "звичайно", "напевно", "може", "повинен", "повинна", "хочу", "хоче",
        "хотів", "буде", "будуть", "було", "була", "були", "немає", "так", "що",
        "хто", "де", "куди", "навіщо", "чому", "скільки", "один", "одна", "одне",
        "два", "три", "чотири", "п'ять", "шість", "сім", "вісім", "дев'ять", "десять",
        "перший", "другий", "третій", "багато", "мало", "більше", "менше", "краще",
        "гірше", "найбільш", "сам", "сама", "мій", "моя", "твій", "наш", "ваш", "свій",
        "своя", "свої", "нас", "вас", "них", "ним", "робити", "зробити", "зроби",
        "робив", "роблю", "робить", "говорити", "сказати", "сказав", "скажи", "знаю",
        "знає", "знати", "думаю", "думає", "думати", "бачити", "бачу", "дивись",
        "дивитися", "йти", "піти", "пішли", "стало", "став", "стати", "час", "року",
        "році", "день", "дня", "тиждень", "місяць", "хвилин", "хвилини", "години",
        "робота", "роботу", "роботи", "працювати", "справа", "справи", "питання",
        "відповідь", "людина", "люди", "життя", "місце", "місця", "сторона", "слово",
        "слова", "текст", "приклад", "випадок", "частина", "кінець", "початок",
        "дякую", "будь", "ласка", "привіт", "поки", "значить", "наприклад", "доречі",
        "взагалі", "нормально", "точно", "правда", "хоча",
    ]
}

extension Character {
    fileprivate var isLatinLetterToken: Bool {
        ("a"..."z").contains(self) || ("A"..."Z").contains(self)
    }

    fileprivate var isCyrillicLetter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (0x0400...0x04FF).contains(scalar.value)
    }
}
