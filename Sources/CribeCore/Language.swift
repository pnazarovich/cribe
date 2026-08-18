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
