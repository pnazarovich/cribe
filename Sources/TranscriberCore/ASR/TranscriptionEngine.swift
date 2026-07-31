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

    public var errorDescription: String? {
        switch self {
        case let .notPrepared(language):
            return "Модель для языка «\(language.displayName)» не загружена."
        }
    }
}

/// Движок распознавания речи: подготовка модели по языку и распознавание PCM-сэмплов 16 кГц.
public protocol TranscriptionEngine: AnyObject {
    /// Скачивает (при необходимости) и загружает модель языка. Повторный вызов — no-op.
    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws

    /// Распознаёт моно-сэмплы 16 кГц. `prompt` — биасинг словарём/контекстом, может быть пустым.
    /// Требует успешного `prepare` для этого языка, иначе бросает `TranscriptionEngineError.notPrepared`.
    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String
}
