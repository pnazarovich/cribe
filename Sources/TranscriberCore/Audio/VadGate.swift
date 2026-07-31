import FluidAudio
import Foundation

/// Silero VAD через FluidAudio (CoreML/ANE): автостоп по 2 с тишины в стриме
/// и обрезка тишины по краям готовой записи.
/// Модель (~2 МБ) скачивается лениво при первом создании гейта.
public actor VadGate {

    /// Отсечка коротких записей — 0.5 c (защита от галлюцинаций и prompt-leak).
    private static let minSpeechSamples = VadManager.sampleRate / 2

    private let vad: VadManager
    /// Для стрима: молчание 2 с → `.speechEnd` → автостоп.
    private let streamConfig = VadSegmentationConfig(minSilenceDuration: 2.0)
    private var streamState = VadStreamState.initial()

    public init() async throws {
        vad = try await VadManager(config: VadConfig())
    }

    /// Обрезает тишину по краям записи. `nil`, если речи нет или её меньше 0.5 c.
    public func trimmed(_ samples: [Float]) async throws -> [Float]? {
        guard samples.count >= Self.minSpeechSamples else { return nil }
        let segments = try await vad.segmentSpeech(samples, config: .default)
        guard let first = segments.first, let last = segments.last else { return nil }

        let rate = VadManager.sampleRate
        let start = max(0, min(first.startSample(sampleRate: rate), samples.count))
        let end = max(start, min(last.endSample(sampleRate: rate), samples.count))
        let speech = Array(samples[start..<end])
        guard speech.count >= Self.minSpeechSamples else { return nil }
        return speech
    }

    /// Сбрасывает состояние стрима перед новой записью.
    public func resetStream() {
        streamState = VadStreamState.initial()
    }

    /// Скармливает чанк (4096 сэмплов 16 кГц). `true` — 2 с тишины после речи, пора останавливаться.
    public func feedStream(_ chunk: [Float]) async throws -> Bool {
        let result = try await vad.processStreamingChunk(chunk, state: streamState, config: streamConfig)
        streamState = result.state
        return result.event?.isEnd == true
    }
}
