import Foundation

/// Состояние ASR-модели.
public enum ASRModelState: Sendable {
    case notLoaded
    /// Доля скачанного, 0...1.
    case downloading(Double)
    case loading
    case ready
}

public enum TranscriptionEngineError: LocalizedError {
    /// `transcribe` вызван до успешного `prepare`.
    case notPrepared(Language)
    /// Движок не умеет отдавать английский задачей декодера.
    case translationUnsupported

    public var errorDescription: String? {
        switch self {
        case let .notPrepared(language):
            return "Модель для языка «\(language.displayName)» не загружена."
        case .translationUnsupported:
            return "Перевод делает ChatGPT — распознавание переводить не умеет."
        }
    }
}

/// Движок распознавания речи: подготовка модели и распознавание PCM-сэмплов 16 кГц.
///
/// Протокол остался после того, как движков стало снова один (Parakeet): им подставляются
/// двойники в тестах, и без него каждый прогон конвейера требовал бы настоящей модели
/// на диске.
public protocol TranscriptionEngine: AnyObject {
    /// Скачивает (при необходимости) и загружает модель. Повторный вызов — no-op.
    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws

    /// Распознаёт моно-сэмплы 16 кГц. `prompt` — биасинг словарём, может быть пустым;
    /// движок вправе его игнорировать (у Parakeet входа для подсказки нет по устройству).
    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String

    /// Тот же проход, но модель сразу отдаёт английский. Умеет не всякий движок — тот,
    /// кто не умеет, обязан бросить `translationUnsupported`, а не вернуть исходный язык
    /// под видом перевода.
    func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String
}

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
}
