import Foundation

/// Состояние ASR-модели для одного языка.
public enum ASRModelState: Sendable {
    case notLoaded
    /// Доля скачанного, 0...1.
    case downloading(Double)
    case loading
    case ready
}

/// Движок распознавания речи: подготовка модели по языку и распознавание PCM-сэмплов 16 кГц.
public protocol TranscriptionEngine: AnyObject {
    /// Скачивает (при необходимости) и загружает модель языка. Повторный вызов — no-op.
    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws

    /// Распознаёт моно-сэмплы 16 кГц. `prompt` — биасинг словарём/контекстом, может быть пустым.
    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String
}
