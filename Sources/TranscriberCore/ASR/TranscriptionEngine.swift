import Foundation

/// Состояние ASR-модели для одного языка.
public enum ASRModelState: Sendable {
    case notLoaded
    /// Доля скачанного, 0...1.
    case downloading(Double)
    case loading
    case ready
}

public enum TranscriptionEngineError: LocalizedError {
    /// `transcribe` вызван до успешного `prepare` для этого языка.
    case notPrepared(Language)
    /// `transcribePreview` вызван до того, как лёгкая модель превью догрузилась.
    case previewNotPrepared
    /// Движок не умеет отдавать сегменты с таймкодами.
    case segmentsUnsupported

    public var errorDescription: String? {
        switch self {
        case let .notPrepared(language):
            return "Модель для языка «\(language.displayName)» не загружена."
        case .previewNotPrepared:
            return "Модель live-превью ещё не загружена."
        case .segmentsUnsupported:
            return "Движок не отдаёт сегменты с таймкодами."
        }
    }
}

/// Кусок распознанного текста с таймкодами относительно начала переданного буфера.
public struct ASRSegment: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Движок распознавания речи: подготовка модели по языку и распознавание PCM-сэмплов 16 кГц.
public protocol TranscriptionEngine: AnyObject {
    /// Скачивает (при необходимости) и загружает модель языка. Повторный вызов — no-op.
    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws

    /// Распознаёт моно-сэмплы 16 кГц. `prompt` — биасинг словарём/контекстом, может быть пустым.
    /// Требует успешного `prepare` для этого языка, иначе бросает `TranscriptionEngineError.notPrepared`.
    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String

    /// То же распознавание, что и `transcribe`, с теми же опциями, но результат — сегменты
    /// с таймкодами. Нужен потоковой финализации: по таймкоду последнего устоявшегося
    /// сегмента считается, сколько записи уже распознано.
    func transcribeSegments(_ samples: [Float], language: Language, prompt: String) async throws -> [ASRSegment]

    /// Смешанная речь (RU + UK): русские сессии распознаёт большая модель вместо turbo.
    /// Значение читают `prepare` и `transcribe`, поэтому ставить его надо до старта сессии.
    func setMixedSpeech(_ enabled: Bool)

    /// Готовит отдельную лёгкую модель для live-превью. Повторный вызов — no-op.
    func preparePreview() async throws

    /// Быстрый черновой проход для живой панели: другая (лёгкая) модель, без промпта.
    /// Требует успешного `preparePreview`, иначе бросает `TranscriptionEngineError.previewNotPrepared`.
    func transcribePreview(_ samples: [Float], language: Language) async throws -> String
}

/// Движок без лёгкой модели превью — законное состояние: вызывающий код откатывается
/// на черновой проход основной модели. Так же и с сегментами: движок без них законен,
/// потоковая финализация просто не включится.
public extension TranscriptionEngine {
    func transcribeSegments(_ samples: [Float], language: Language, prompt: String) async throws -> [ASRSegment] {
        throw TranscriptionEngineError.segmentsUnsupported
    }

    /// Движок с одной моделью на язык — законное состояние: выбирать ему нечего.
    func setMixedSpeech(_ enabled: Bool) {}

    func preparePreview() async throws {}

    func transcribePreview(_ samples: [Float], language: Language) async throws -> String {
        throw TranscriptionEngineError.previewNotPrepared
    }
}
