import Foundation
import WhisperKit

/// WhisperKit-движок: держит по одному прогретому инстансу на язык.
public final class WhisperEngine: TranscriptionEngine {
    /// Модели и токенайзеры лежат в ~/Library/Application Support/Transcriber/models.
    private static let downloadBase: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriber", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)

    private var pipelines: [Language: WhisperKit] = [:]

    public init() {}

    public func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        _ = try await pipeline(for: language, onState: onState)
    }

    public func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        let pipe = try await pipeline(for: language) { _ in }

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
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func pipeline(
        for language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws -> WhisperKit {
        if let ready = pipelines[language] {
            onState(.ready)
            return ready
        }

        onState(.downloading(0))
        let folder = try await WhisperKit.download(
            variant: language.whisperModel,
            downloadBase: Self.downloadBase,
            progressCallback: { progress in onState(.downloading(progress.fractionCompleted)) }
        )

        onState(.loading)
        let pipe = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: Self.downloadBase,
                prewarm: true,
                load: true
            )
        )

        pipelines[language] = pipe
        onState(.ready)
        return pipe
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
