import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    case ru
    case uk
    case en

    public var displayName: String {
        switch self {
        case .ru: return "Русский"
        case .uk: return "Українська"
        case .en: return "English"
        }
    }

    /// Пишется ли язык кириллицей. От этого зависит, есть ли смысл в кириллических
    /// вариантах словаря: английскую сессию распознаватель отдаёт латиницей.
    public var isCyrillic: Bool {
        self != .en
    }

    /// Язык, на который человек с этой сессией сбивается посреди фразы. Русский с
    /// украинским путает и сам распознаватель: языки близкие, часть слов общая, и
    /// украинская вставка в русском окне выходит фонетическим мусором по звучанию.
    /// Английскому пары нет — с ним такой беды не наблюдалось.
    ///
    /// Пара двусторонняя, но так стало не сразу. Обратное направление держали выключенным
    /// из общего соображения: украинскую сессию судила бы turbo — модель слабее собственной
    /// large-v3, да ещё и склонная тянуть украинское в русское написание. Соображение
    /// оказалось неверным, и это показал замер (2026-08-09, две украинские диктовки
    /// владельца с русской вставкой). Обе без второго мнения ломались ровно так, как
    /// ломалась когда-то русская: «Он говорит: я не смогу приехать раньше среды» выходило
    /// «Він говорить, що не зможе приїхати раніше зі зору», а «Оплата прошла успешно,
    /// спасибо за заказ» — «оплата пройшла успішно, спосіб за заказ». Со вторым мнением обе
    /// вернулись дословно верными. Судьёй turbo справляется.
    public var neighbour: Language? {
        switch self {
        case .ru: return .uk
        case .uk: return .ru
        case .en: return nil
        }
    }
}

/// Языки, на которых человек диктует, — набор, а не один.
///
/// Отмечать можно любое сочетание: распознавание с Ultra без подсказки письменности само
/// слышит, на каком языке речь, и выбор языка перестал быть приказом движку. Он нужен
/// чистке — у неё свои правила для каждого языка, — и её язык определяется по самому
/// тексту диктовки, когда отмечено несколько.
extension Language {
    /// Порядок, в котором языки показываются и в котором выбирается «первый».
    public static let ordered: [Language] = [.ru, .uk, .en]

    /// Что сказать распознаванию до того, как текст есть.
    ///
    /// Английский — только когда он отмечен один: там подсказка включает фильтр, который
    /// отсекает кириллицу. Во всех остальных сочетаниях — кириллический язык, то есть без
    /// фильтра (см. `ParakeetEngine.scriptHint`): иначе при «русский + английский»
    /// английская подсказка выкинула бы всю русскую речь.
    public static func recognition(for enabled: Set<Language>) -> Language {
        enabled == [.en] ? .en : (ordered.first { $0 != .en && enabled.contains($0) } ?? .ru)
    }

    /// Язык готового текста, когда отмечено несколько.
    ///
    /// Первая версия считала буквы, и проверка перед выпуском поймала её на двух вещах,
    /// обе — на переводе. «Короче, сделай pull request в GitHub» при русском с английским
    /// уходило английским: латинских букв больше, — и перевод на английский молча снимался.
    /// «Слушай, там нічого не работает» уходило украинским: одна «і» и ни одной «ы».
    /// Отсюда два правила.
    ///
    /// Английский — только когда кириллицы почти нет: втрое меньше латиницы. Русскую фразу
    /// с названиями это не задевает (кириллицы в ней всегда много), а английскую с одним
    /// русским именем — пропускает.
    ///
    /// Русский против украинского — по характерным словам, а не по буквам, и от основного
    /// языка (первого отмеченного) уходим только при явном перевесе другого: хотя бы два
    /// его слова и вдвое больше, чем слов основного. Смешанная речь — это и есть основной
    /// язык с вкраплениями; вкрапление не имеет права перекрасить всю фразу.
    public static func resolve(_ text: String, among enabled: Set<Language>) -> Language {
        let chosen = ordered.filter(enabled.contains)
        guard chosen.count > 1 else { return chosen.first ?? .ru }

        var latin = 0, cyrillic = 0
        for scalar in text.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z": latin += 1
            case "а"..."я", "ё", "і", "ї", "є", "ґ": cyrillic += 1
            default: break
            }
        }
        if enabled.contains(.en), latin > cyrillic * 3 { return .en }

        let slavic = chosen.filter { $0 != .en }
        guard slavic.count > 1 else { return slavic.first ?? .en }

        let primary = slavic[0]
        let other = slavic[1]
        let words = text.lowercased()
            .split { !$0.isLetter && $0 != "'" && $0 != "’" }
            .map(String.init)
        let scores = (
            ru: words.filter(isRussianMarker).count,
            uk: words.filter(isUkrainianMarker).count
        )
        let own = primary == .ru ? scores.ru : scores.uk
        let theirs = other == .ru ? scores.ru : scores.uk
        return theirs >= 2 && theirs >= own * 2 + 1 ? other : primary
    }

    /// Слово, которого в украинском нет: русские буквы или частое русское служебное слово.
    static func isRussianMarker(_ word: String) -> Bool {
        word.contains { "ыэъё".contains($0) } || russianWords.contains(word)
    }

    /// Слово, которого в русском нет: украинские буквы или частое украинское служебное слово.
    static func isUkrainianMarker(_ word: String) -> Bool {
        word.contains { "іїєґ".contains($0) } || ukrainianWords.contains(word)
    }

    /// Частые слова, которые пишутся только по-русски, — и только однозначные: «так», «ну»,
    /// «давай», «просто» есть в обоих языках и ничего не говорят.
    private static let russianWords: Set<String> = [
        "что", "это", "как", "уже", "еще", "надо", "очень", "сейчас", "потому", "если",
        "когда", "только", "тоже", "нет", "будет", "вот", "спасибо", "хорошо", "ладно",
        "сделать", "сделаю", "сделай", "можно", "нужно", "чтобы", "где", "почему",
    ]

    /// Частые слова, которые пишутся только по-украински.
    private static let ukrainianWords: Set<String> = [
        "що", "це", "як", "ще", "вже", "треба", "дуже", "зараз", "тому", "якщо", "коли",
        "бо", "буде", "було", "дякую", "добре", "гаразд", "зробити", "зроблю", "зроби",
        "можна", "потрібно", "щоб", "де", "чому", "немає", "нема", "також", "мені", "ось",
    ]

    /// Как назвать набор в строке состояния: «Русский + Українська».
    public static func displayName(of enabled: Set<Language>) -> String {
        ordered.filter(enabled.contains).map(\.displayName).joined(separator: " + ")
    }
}

/// Язык, на который переводит правый ⌥.
///
/// Отдельный тип, а не `Language`: те три — языки, которые умеет РАСПОЗНАВАТЬ движок, и
/// список у них жёстко привязан к весам модели. Здесь же переводит GPT, и ему всё равно,
/// какой язык просить, — поэтому список задаёт польза, а не техника.
public enum TranslationTarget: String, CaseIterable, Codable, Sendable {
    case en, pl, uk, ru, de, es, fr, it, pt, nl
    case cs, tr, ar, he, zh, ja, ko, hi, id, vi

    /// Как язык называется в настройках. Порядок в `allCases` — он же в списке выбора:
    /// сперва те, на которые переводят чаще, дальше остальные.
    public var displayName: String {
        switch self {
        case .en: return "Английский"
        case .pl: return "Польский"
        case .uk: return "Украинский"
        case .ru: return "Русский"
        case .de: return "Немецкий"
        case .es: return "Испанский"
        case .fr: return "Французский"
        case .it: return "Итальянский"
        case .pt: return "Португальский"
        case .nl: return "Нидерландский"
        case .cs: return "Чешский"
        case .tr: return "Турецкий"
        case .ar: return "Арабский"
        case .he: return "Иврит"
        case .zh: return "Китайский"
        case .ja: return "Японский"
        case .ko: return "Корейский"
        case .hi: return "Хинди"
        case .id: return "Индонезийский"
        case .vi: return "Вьетнамский"
        }
    }

    /// Как язык назван в подсказке модели.
    ///
    /// По-английски, и это не небрежность: английское название языка модель понимает
    /// однозначно, а вот русское «нидерландский» рядом с «голландский» — уже повод гадать.
    public var promptName: String {
        switch self {
        case .en: return "English"
        case .pl: return "Polish"
        case .uk: return "Ukrainian"
        case .ru: return "Russian"
        case .de: return "German"
        case .es: return "Spanish"
        case .fr: return "French"
        case .it: return "Italian"
        case .pt: return "Portuguese"
        case .nl: return "Dutch"
        case .cs: return "Czech"
        case .tr: return "Turkish"
        case .ar: return "Arabic"
        case .he: return "Hebrew"
        case .zh: return "Chinese (Simplified)"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .hi: return "Hindi"
        case .id: return "Indonesian"
        case .vi: return "Vietnamese"
        }
    }

    /// Название после предлога «на»: «перевод на польский», «перевод на иврит».
    ///
    /// Просто строчными, и этого достаточно: все названия в списке — либо прилагательные
    /// на «-ский», у которых винительный падеж совпадает с именительным, либо несклоняемые
    /// существительные («иврит», «хинди»). Склонять нечего.
    public var afterOn: String { displayName.lowercased() }

    /// Тот же язык, что и у диктовки, — тогда переводить нечего.
    ///
    /// Случай не выдуманный: список целей включает и русский с украинским, и человек
    /// вправе выбрать «Русский», диктуя по-русски. Просить модель перевести текст на его
    /// же язык — верный способ получить пересказ вместо текста.
    public func matches(_ language: Language) -> Bool {
        switch self {
        case .ru: return language == .ru
        case .uk: return language == .uk
        case .en: return language == .en
        default: return false
        }
    }
}
