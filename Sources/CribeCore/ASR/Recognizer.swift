import Foundation

/// Чем слушать речь. Выбор человека, а не наш: у каждого варианта своя цена.
public enum RecognitionEngine: String, Codable, CaseIterable, Sendable {
    /// Whisper turbo — быстрый вариант, до сих пор бывший единственным.
    case fast
    /// Whisper large-v3 — та же архитектура, но полная модель. Вдвое дольше.
    case precise
    /// Parakeet TDT v3 от NVIDIA — вдесятеро быстрее turbo и точнее его на русском,
    /// но латинские слова пишет кириллицей.
    case parakeet

    /// Обязана ли каждая диктовка проходить GPT-чистку, даже самая короткая.
    ///
    /// Обычно короткие диктовки пускают мимо третьего слоя: на «ок» чистка ничего не
    /// меняет, а стоит целого круга к модели. С Parakeet это перестаёт быть правдой —
    /// он один-единственный записывает «Гитхаб» и «пул реквест» кириллицей, и вернуть
    /// им латиницу может только GPT (см. `PostProcessor`). Слово «deploy», сказанное
    /// в одиночку, — ровно тот случай, где пропуск слоя виден больше всего.
    public var alwaysCleans: Bool { self == .parakeet }
}

/// Развилка между движками распознавания: конвейеру он один, а внутри их два.
///
/// Появился ради выбора в настройках. `DictationController` берёт движок один раз при
/// создании и держит его до конца жизни приложения, поэтому переключать распознавание
/// на лету может только тот, кто стоит между ними.
///
/// Не всё уходит выбранному. Превью живёт на своей лёгкой модели, а повторный разбор
/// записи называет вариант модели по имени — и то и другое понятия Whisper, и в Parakeet
/// им идти незачем и не с чем.
public final class Recognizer: TranscriptionEngine, @unchecked Sendable {
    public let whisper: WhisperEngine
    public let parakeet: ParakeetEngine

    /// Меняется из настроек, читается диктовкой — как и `prefersAccuracy` у Whisper.
    public var mode: RecognitionEngine = .fast {
        didSet { whisper.prefersAccuracy = mode == .precise }
    }

    public init(whisper: WhisperEngine, parakeet: ParakeetEngine = ParakeetEngine()) {
        self.whisper = whisper
        self.parakeet = parakeet
    }

    /// Движок, которому идёт диктовка прямо сейчас.
    private var active: TranscriptionEngine {
        mode == .parakeet ? parakeet : whisper
    }

    /// Скачана ли модель выбранного движка — тот же вопрос, что и у Whisper, только теперь
    /// его задают не одному движку.
    public func isInstalled(for language: Language) -> Bool {
        mode == .parakeet ? ParakeetEngine.isInstalled : whisper.isInstalled(for: language)
    }

    public func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        try await active.prepare(language: language, onState: onState)
    }

    public func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        try await active.transcribe(samples, language: language, prompt: prompt)
    }

    public func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String {
        try await active.transcribe(samples, language: language, prompt: prompt, translating: translating)
    }

    public func transcribeDetailed(
        _ samples: [Float],
        language: Language,
        prompt: String
    ) async throws -> Transcript {
        try await active.transcribeDetailed(samples, language: language, prompt: prompt)
    }

    public func transcribeSegments(
        _ samples: [Float],
        language: Language,
        prompt: String
    ) async throws -> [ASRSegment] {
        try await active.transcribeSegments(samples, language: language, prompt: prompt)
    }

    public func reconsideringNeighbour(
        _ text: String,
        samples: [Float],
        language: Language,
        prompt: String
    ) async -> NeighbourPass {
        await active.reconsideringNeighbour(text, samples: samples, language: language, prompt: prompt)
    }

    /// Вариант модели назван по имени — это всегда Whisper: имена вариантов её собственные,
    /// и просит их повторный разбор записи из истории.
    public func prepare(
        variant: String,
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws {
        try await whisper.prepare(variant: variant, language: language, onState: onState)
    }

    public func transcribe(
        _ samples: [Float],
        language: Language,
        variant: String,
        prompt: String
    ) async throws -> String {
        try await whisper.transcribe(samples, language: language, variant: variant, prompt: prompt)
    }

    /// Живая панель работает на своей лёгкой модели — она у Whisper, и выбор её не касается.
    public func preparePreview() async throws {
        try await whisper.preparePreview()
    }

    public func transcribePreview(_ samples: [Float], language: Language) async throws -> String {
        try await whisper.transcribePreview(samples, language: language)
    }
}
