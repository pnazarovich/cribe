import Foundation

public enum Language: String, CaseIterable, Codable, Sendable {
    case ru
    case uk
    case en

    /// Модель сессии — её выбирает только язык, и больше ничто (см. `WhisperModel`).
    /// Английский идёт на ту же turbo, что и русский:
    /// модель мультиязычная, на английском она сильнее всего, и отдельных гигабайтов
    /// третий язык не стоит (см. `ModelBundle`).
    public var whisperModel: String {
        switch self {
        case .ru, .en: return WhisperModel.turbo
        case .uk: return WhisperModel.large
        }
    }

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
}

/// Модель распознавания как единица скачивания: один вариант Whisper и языки, которые его делят.
///
/// Языки — это не модели. Русский и английский живут на одной turbo, и показывать их двумя
/// строками по 1,5 ГБ значит врать про вес; удалять порознь их тем более нельзя — файлы одни
/// и те же, и «удалил английский» означало бы «сломал русский».
public struct ModelBundle: Identifiable, Hashable, Sendable {
    /// Вариант WhisperKit — он же ключ: одна папка на диске, одна загрузка, одно удаление.
    public let variant: String
    /// Языки, которые обслуживает эта модель, в порядке `Language.allCases`.
    public let languages: [Language]

    public var id: String { variant }

    /// Языки строкой: «Русский · English».
    public var displayName: String {
        languages.map(\.displayName).joined(separator: " · ")
    }

    /// Язык, от имени которого ходим в движок: тот ключует модели вариантом, так что любой
    /// из языков модели приведёт к той же папке на диске.
    public var primaryLanguage: Language {
        languages.first ?? .ru
    }

    /// Сколько весит модель. Первый запуск называет число до нажатия кнопки и качает модели
    /// по отдельности: 1,5 ГБ и 2,9 ГБ — разные решения, и тому, кому нужен только русский,
    /// незачем отдавать 4,4 ГБ. Числа — вес репозиториев WhisperKit.
    public var sizeGB: Double {
        variant == WhisperModel.large ? 2.9 : 1.5
    }

    /// Тот же размер подписью в интерфейсе (запятая — десятичный разделитель русского).
    public var sizeText: String {
        variant == WhisperModel.large ? "2,9 ГБ" : "1,5 ГБ"
    }

    /// Все модели в порядке первого языка, который их просит.
    public static let all: [ModelBundle] = {
        var order: [String] = []
        var languages: [String: [Language]] = [:]
        for language in Language.allCases {
            let variant = language.whisperModel
            if languages[variant] == nil { order.append(variant) }
            languages[variant, default: []].append(language)
        }
        return order.map { ModelBundle(variant: $0, languages: languages[$0] ?? []) }
    }()

    /// Модель, на которой работает язык.
    public static func bundle(for language: Language) -> ModelBundle {
        all.first { $0.variant == language.whisperModel }
            ?? ModelBundle(variant: language.whisperModel, languages: [language])
    }
}

/// Варианты моделей Whisper. Русский и английский обслуживает turbo, украинский — large-v3.
///
/// Русскую сессию когда-то уводил на large-v3 тумблер «Смешанная речь (RU + UK)» — из общего
/// соображения, что turbo слабее на украинском (22.8 % WER против 13.7 %). Замена модели
/// стоила 5.5–5.9× времени прохода (1.4 c против 7.9 c на семисекундной диктовке), потому что
/// каждый токен промпта — это отдельный проход декодера: 48 мс на large-v3 против 7.5 мс на
/// turbo. Русскую часть large-v3 при этом украинизировал («провєріть пріложення», «всьо
/// нормальна»), то есть портил ровно то, ради чего его брали. Сам тумблер потом свёлся
/// к добавке в промпт и в итоге снят целиком (см. `PromptBuilder`), но вывод про модель
/// от этого не изменился: смешанную речь моделью не лечат.
public enum WhisperModel {
    /// Быстрая модель русских и английских сессий.
    public static let turbo = "openai_whisper-large-v3-v20240930_turbo"
    /// Большая модель — основная для украинского.
    public static let large = "openai_whisper-large-v3"
}
