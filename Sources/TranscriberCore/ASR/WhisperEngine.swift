import Foundation
import WhisperKit

/// WhisperKit-движок: держит по одному прогретому инстансу на язык.
/// Кэш и список идущих загрузок сериализованы через DispatchQueue, параллельные
/// `prepare` одного языка склеиваются в одну загрузку — второй раз многогигабайтная
/// модель не качается.
public final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    /// Модели и токенайзеры лежат в ~/Library/Application Support/Transcriber/models.
    private static let downloadBase: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriber", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)

    private let queue = DispatchQueue(label: "online.nazarovych.transcriber.whisper")
    private var pipelines: [Language: WhisperKit] = [:]
    /// Идущие загрузки. Результат кладётся в `pipelines`, поэтому Task<Void, Error>:
    /// WhisperKit не Sendable и не может быть значением задачи.
    private var loading: [Language: Task<Void, Error>] = [:]

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

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Private

    /// Одна загрузка на язык: скачивание (только если моделей ещё нет на диске) + прогрев.
    /// Сама кладёт результат в кэш и снимает себя со списка идущих — и при успехе, и при ошибке.
    private func loadTask(
        for language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) -> Task<Void, Error> {
        Task {
            do {
                let folder: URL
                if let local = Self.localModelFolder(for: language) {
                    folder = local
                } else {
                    onState(.downloading(0))
                    folder = try await WhisperKit.download(
                        variant: language.whisperModel,
                        downloadBase: Self.downloadBase,
                        progressCallback: { progress in onState(.downloading(progress.fractionCompleted)) }
                    )
                }

                onState(.loading)
                let pipe = try await WhisperKit(
                    WhisperKitConfig(
                        modelFolder: folder.path,
                        tokenizerFolder: Self.downloadBase,
                        prewarm: true,
                        load: true
                    )
                )

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

    /// Папка уже скачанной модели, если она на месте целиком. Иначе nil — тогда идём в сеть.
    /// Раскладка HubApi: <downloadBase>/models/<repo>/<variant>.
    private static func localModelFolder(for language: Language) -> URL? {
        let folder = downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(language.whisperModel, isDirectory: true)

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
