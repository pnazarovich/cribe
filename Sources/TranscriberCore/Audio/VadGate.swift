import FluidAudio
import Foundation

/// Поверхность VAD, на которую опирается `DictationController`: вердикт по готовой записи
/// и стрим для автостопа.
///
/// Протокол нужен ровно затем же, зачем `AudioCapturing` и `TranscriptionEngine`: конвейер
/// не должен знать, кто выносит вердикт, а тесты подставляют заглушку вместо CoreML-модели —
/// иначе прогон тянул бы её из сети на чистой машине.
public protocol SpeechGating: Sendable {
    /// Обрезает тишину по краям записи. `nil` — речи нет.
    func trimmed(_ samples: [Float]) async throws -> [Float]?
    /// Сбрасывает состояние стрима перед новой записью.
    func resetStream() async
    /// Скармливает чанк записи. `true` — пора останавливаться по тишине.
    func feedStream(_ chunk: [Float]) async throws -> Bool
}

/// Silero VAD через FluidAudio (CoreML/ANE): автостоп по 2 с тишины в стриме
/// и обрезка тишины по краям готовой записи.
/// Модель (~2 МБ) скачивается лениво при первом создании гейта.
public actor VadGate: SpeechGating {

    /// Отсечка коротких записей — 0.5 c (защита от галлюцинаций и prompt-leak).
    private static let minSpeechSamples = VadManager.sampleRate / 2

    private let vad: VadManager
    /// Для стрима: молчание 2 с → `.speechEnd` → автостоп.
    private let streamConfig = VadSegmentationConfig(minSilenceDuration: 2.0)
    private var streamState = VadStreamState.initial()
    /// Цепочка вызовов feedStream: актор реентерабелен, а `streamState` — read-modify-write.
    private var inFlight: Task<Bool, Error>?
    /// Номер записи: результат, посчитанный до `resetStream()`, выбрасывается.
    private var generation = 0

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
        generation += 1
        streamState = VadStreamState.initial()
    }

    /// Скармливает чанк (4096 сэмплов 16 кГц). `true` — 2 с тишины после речи, пора останавливаться.
    /// Вызовы выстраиваются в очередь, чтобы состояние стрима обновлялось строго по порядку.
    public func feedStream(_ chunk: [Float]) async throws -> Bool {
        // Поколение фиксируем в момент постановки в очередь, а не в начале счёта: чанк,
        // вставший в очередь до `resetStream()`, доходит до `process` уже после него
        // и иначе засеял бы новую запись звуком предыдущей.
        let queuedGeneration = generation
        let previous = inFlight
        let task = Task { [self] in
            _ = try? await previous?.value
            return try await process(chunk, generation: queuedGeneration)
        }
        inFlight = task
        return try await task.value
    }

    private func process(_ chunk: [Float], generation queued: Int) async throws -> Bool {
        // Пока чанк стоял в очереди, могла начаться новая запись — он уже не про неё.
        guard queued == generation else { return false }
        let result = try await vad.processStreamingChunk(chunk, state: streamState, config: streamConfig)
        // И то же самое после счёта: `processStreamingChunk` — точка приостановки.
        guard queued == generation else { return false }
        streamState = result.state
        return result.event?.isEnd == true
    }
}
