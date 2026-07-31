import Foundation
import WhisperKit

/// WhisperKit-движок: держит по одному прогретому инстансу на язык плюс отдельный
/// лёгкий инстанс (whisper-tiny) для live-превью.
/// Кэш и список идущих загрузок сериализованы через DispatchQueue, параллельные
/// `prepare` одного языка склеиваются в одну загрузку — второй раз многогигабайтная
/// модель не качается.
public final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    /// Модели и токенайзеры лежат в ~/Library/Application Support/Transcriber/models.
    private static let downloadBase: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriber", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)

    /// Модель live-превью: multilingual tiny (~150 МБ) — качество черновое, зато проход
    /// идёт десятки миллисекунд вместо ~1.3 c у большой модели сессии.
    private static let previewVariant = "openai_whisper-tiny"

    private let queue = DispatchQueue(label: "online.nazarovych.transcriber.whisper")
    private var pipelines: [Language: WhisperKit] = [:]
    /// Идущие загрузки. Результат кладётся в `pipelines`, поэтому Task<Void, Error>:
    /// WhisperKit не Sendable и не может быть значением задачи.
    private var loading: [Language: Task<Void, Error>] = [:]
    /// Отдельный инстанс превью и его загрузка — тот же приём, но ключ один на всё приложение:
    /// tiny мультиязычная, язык форсируется в опциях декодирования.
    private var previewPipeline: WhisperKit?
    private var previewLoading: Task<Void, Error>?

    public init() {}

    public func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        let pending: (task: Task<Void, Error>, joined: Bool)? = queue.sync {
            if pipelines[language] != nil { return nil }
            if let inflight = loading[language] { return (inflight, true) }
            let started = loadTask(for: language, onState: onState)
            loading[language] = started
            return (started, false)
        }

        // Модель уже готова — повторный prepare ничего не делает.
        guard let pending else {
            onState(.ready)
            return
        }

        // Прогресс скачивания получает тот, кто загрузку начал; присоединившийся — только итог.
        if pending.joined { onState(.loading) }

        do {
            try await pending.task.value
            onState(.ready)
        } catch {
            onState(.notLoaded)
            throw error
        }
    }

    public func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        let cached = queue.sync { pipelines[language] }
        guard let pipe = cached else {
            throw TranscriptionEngineError.notPrepared(language)
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language.rawValue,
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            promptTokens: promptTokens(prompt, pipe: pipe),
            chunkingStrategy: .vad
        )

        return Self.text(of: try await pipe.transcribe(audioArray: samples, decodeOptions: options))
    }

    public func preparePreview() async throws {
        let pending: Task<Void, Error>? = queue.sync {
            if previewPipeline != nil { return nil }
            if let inflight = previewLoading { return inflight }
            let started = previewLoadTask()
            previewLoading = started
            return started
        }
        // Модель уже готова — повторный вызов ничего не делает.
        guard let pending else { return }
        try await pending.value
    }

    public func transcribePreview(_ samples: [Float], language: Language) async throws -> String {
        guard let pipe = queue.sync(execute: { previewPipeline }) else {
            throw TranscriptionEngineError.previewNotPrepared
        }

        // Без промпта: биасинг словарём стоит токенов декодера, а превью — черновик,
        // латиницу гарантирует слой 2 на финале.
        // `windowClipTime: 0` — единственное отличие от опций финала. По умолчанию это 1 c,
        // которую WhisperKit срезает с конца окна против галлюцинаций, а вместе с ней
        // выбрасывает целиком любую запись короче секунды: `while seek < seekClipEnd - windowPadding`
        // не выполняется ни разу и превью возвращается пустым (замерено). Для черновика
        // защита не нужна — финальный проход считает те же опции, что и раньше.
        let options = DecodingOptions(
            task: .transcribe,
            language: language.rawValue,
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            windowClipTime: 0,
            chunkingStrategy: .vad
        )

        return Self.text(of: try await pipe.transcribe(audioArray: samples, decodeOptions: options))
    }

    // MARK: - Private

    private static func text(of results: [TranscriptionResult]) -> String {
        results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Одна загрузка на язык: скачивание (только если моделей ещё нет на диске) + прогрев.
    /// Сама кладёт результат в кэш и снимает себя со списка идущих — и при успехе, и при ошибке.
    private func loadTask(
        for language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) -> Task<Void, Error> {
        Task {
            do {
                let pipe = try await Self.loadPipeline(variant: language.whisperModel, onState: onState)
                self.queue.sync {
                    self.pipelines[language] = pipe
                    self.loading[language] = nil
                }
            } catch {
                // Ничего не кэшируем — следующий prepare попробует снова.
                self.queue.sync { self.loading[language] = nil }
                throw error
            }
        }
    }

    /// То же самое для модели превью: прогресс никому не показываем — загрузка идёт
    /// фоном при старте приложения, а до её конца превью считает большая модель.
    private func previewLoadTask() -> Task<Void, Error> {
        Task {
            do {
                let pipe = try await Self.loadPipeline(variant: Self.previewVariant, onState: { _ in })
                self.queue.sync {
                    self.previewPipeline = pipe
                    self.previewLoading = nil
                }
            } catch {
                self.queue.sync { self.previewLoading = nil }
                throw error
            }
        }
    }

    /// Скачивание (только если моделей ещё нет на диске) + прогрев одного варианта.
    private static func loadPipeline(
        variant: String,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws -> WhisperKit {
        let folder: URL
        if let local = localModelFolder(variant: variant) {
            folder = local
        } else {
            onState(.downloading(0))
            folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                progressCallback: { progress in onState(.downloading(progress.fractionCompleted)) }
            )
        }

        onState(.loading)
        return try await WhisperKit(
            WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: downloadBase,
                prewarm: true,
                load: true
            )
        )
    }

    /// Папка уже скачанной модели, если она на месте целиком. Иначе nil — тогда идём в сеть.
    /// Раскладка HubApi: <downloadBase>/models/<repo>/<variant>.
    private static func localModelFolder(variant: String) -> URL? {
        let folder = downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)

        // Те же три модели проверяет WhisperKit при загрузке; недокачанную папку не принимаем.
        let required = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let complete = required.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).\(ext)").path)
            }
        }
        return complete ? folder : nil
    }

    /// Токены промпта без спецтокенов — их WhisperKit подставляет сам.
    private func promptTokens(_ prompt: String, pipe: WhisperKit) -> [Int]? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let tokenizer = pipe.tokenizer else { return nil }

        let tokens = tokenizer
            .encode(text: " " + text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }
}
