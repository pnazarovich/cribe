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

    /// Тот же проход, но модель сразу отдаёт английский: у Whisper это отдельная задача
    /// декодера, а не второй вызов. Ради неё перевод и не зависит больше ни от сети,
    /// ни от входа в ChatGPT.
    func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String

    /// То же распознавание, что и `transcribe`, с теми же опциями, но результат — сегменты
    /// с таймкодами. Нужен потоковой финализации: по таймкоду последнего устоявшегося
    /// сегмента считается, сколько записи уже распознано.
    func transcribeSegments(_ samples: [Float], language: Language, prompt: String) async throws -> [ASRSegment]

    /// Готовит вариант модели, названный явно, — язык при этом остаётся своим.
    /// Нужно повторному разбору записи из истории: у русской сессии вариант выбирает язык
    /// (turbo), а на повторе человек вправе попросить large-v3, не становясь украинцем.
    func prepare(
        variant: String,
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws

    /// То же распознавание, что и `transcribe`, но на явно названном варианте модели.
    func transcribe(_ samples: [Float], language: Language, variant: String, prompt: String) async throws -> String

    /// Перечитывает в готовом тексте фразы, звучащие на соседнем языке (см. `SecondOpinion`).
    /// Зовётся один раз на диктовку, когда текст собран целиком, — и только там: середина
    /// длинной диктовки приезжает фоновыми проходами, и проверка внутри распознавания
    /// её не увидела бы.
    func reconsideringNeighbour(
        _ text: String,
        samples: [Float],
        language: Language,
        prompt: String
    ) async -> NeighbourPass

    /// Готовит отдельную лёгкую модель для live-превью. Повторный вызов — no-op.
    func preparePreview() async throws

    /// Быстрый черновой проход для живой панели: другая (лёгкая) модель, без промпта.
    /// Требует успешного `preparePreview`, иначе бросает `TranscriptionEngineError.previewNotPrepared`.
    func transcribePreview(_ samples: [Float], language: Language) async throws -> String
}

/// Движок без лёгкой модели превью — законное состояние: вызывающий код откатывается
/// на черновой проход основной модели. Так же и с сегментами: движок без них законен,
/// потоковая финализация просто не включится. И с выбором варианта: движку с одной моделью
/// выбирать не из чего — он делает обычный проход.
public extension TranscriptionEngine {
    /// Двойники в тестах перевод не изображают — им хватает обычного прохода.
    func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String {
        try await transcribe(samples, language: language, prompt: prompt)
    }

    func transcribeSegments(_ samples: [Float], language: Language, prompt: String) async throws -> [ASRSegment] {
        throw TranscriptionEngineError.segmentsUnsupported
    }

    func prepare(
        variant: String,
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws {
        try await prepare(language: language, onState: onState)
    }

    func transcribe(
        _ samples: [Float],
        language: Language,
        variant: String,
        prompt: String
    ) async throws -> String {
        try await transcribe(samples, language: language, prompt: prompt)
    }

    /// Движок без второго мнения — законное состояние: текст остаётся как распознан.
    func reconsideringNeighbour(
        _ text: String,
        samples: [Float],
        language: Language,
        prompt: String
    ) async -> NeighbourPass {
        NeighbourPass(text: text, replaced: 0)
    }

    func preparePreview() async throws {}

    func transcribePreview(_ samples: [Float], language: Language) async throws -> String {
        throw TranscriptionEngineError.previewNotPrepared
    }
}
