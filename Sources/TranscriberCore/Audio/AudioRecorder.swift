import Accelerate
import AVFoundation
import Foundation
import OSLog

public enum AudioRecorderError: Error, LocalizedError {
    case noInputDevice
    case converterUnavailable

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "Микрофон недоступен"
        case .converterUnavailable:
            return "Не удалось создать конвертер аудио в 16 кГц"
        }
    }
}

/// Захват микрофона: AVAudioEngine → AVAudioConverter → 16 кГц mono Float32.
/// Публичный API вызывается с главного потока, tap приходит с аудиопотока —
/// общее состояние закрыто `lock`.
public final class AudioRecorder {

    /// Частота дискретизации, которую ждут VAD и Whisper.
    public static let sampleRate: Double = 16_000
    /// Размер чанка для Silero VAD — 4096 сэмплов (256 мс).
    public static let chunkSize = 4096

    /// Уровень сигнала (RMS 0…1) на каждый блок tap-а, ~10 Гц. Речь обычно даёт 0.02…0.2.
    public var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { levelHandler } }
        set { lock.withLock { levelHandler = newValue } }
    }

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!  // параметры константны и валидны

    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "AudioRecorder")
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // Под lock:
    private var samples: [Float] = []
    private var pending: [Float] = []
    private var chunkHandler: (@Sendable ([Float]) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var isRecording = false

    // Только главный поток (converter читается с аудиопотока, но меняется
    // строго после removeTap, который гарантирует отсутствие вызовов tap-а).
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?

    public init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    /// Прогрев: поднимает движок с «тихим» tap-ом, чтобы старт записи был мгновенным.
    public func prepare() {
        do {
            try startEngine()
        } catch {
            logger.error("Прогрев движка не удался: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Начинает запись. `onChunk` вызывается с аудиопотока чанками по 4096 сэмплов 16 кГц mono.
    public func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            chunkHandler = onChunk
            isRecording = true
        }
        do {
            try startEngine()
        } catch {
            lock.withLock {
                isRecording = false
                chunkHandler = nil
            }
            throw error
        }
    }

    /// Останавливает запись и возвращает весь записанный буфер. Движок остаётся прогретым.
    public func stop() -> [Float] {
        lock.withLock {
            isRecording = false
            chunkHandler = nil
            pending.removeAll(keepingCapacity: true)
            return samples
        }
    }

    // MARK: - Движок

    private func startEngine() throws {
        if !tapInstalled {
            try installTap()
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: format, to: Self.targetFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.chunkSize), format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true
    }

    /// Смена устройства ввода (AirPods и т.п.) — пересобираем tap под новый формат.
    private func handleConfigurationChange() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            converter = nil
        }
        do {
            try startEngine()
        } catch {
            logger.error("Пересборка tap-а не удалась: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Аудиопоток

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer), !converted.isEmpty else { return }

        var chunks: [[Float]] = []
        var chunkSink: (@Sendable ([Float]) -> Void)?
        var levelSink: (@Sendable (Float) -> Void)?

        lock.withLock {
            guard isRecording else { return }
            samples.append(contentsOf: converted)
            pending.append(contentsOf: converted)
            while pending.count >= Self.chunkSize {
                chunks.append(Array(pending.prefix(Self.chunkSize)))
                pending.removeFirst(Self.chunkSize)
            }
            chunkSink = chunkHandler
            levelSink = levelHandler
        }

        levelSink?(Self.rms(converted))
        if let chunkSink {
            for chunk in chunks {
                chunkSink(chunk)
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter = converter else { return nil }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return min(1, meanSquare.squareRoot())
    }
}
