import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
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
    /// UID выбранного микрофона; nil — системный по умолчанию. Применяется при каждой сборке tap-а.
    private var inputDeviceUID: String?

    /// Только аудиопоток: гасит повтор лога о сбоях конвертации.
    private var conversionFailureLogged = false

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

    /// Выбирает микрофон по UID (`nil` или неизвестный UID — системный по умолчанию).
    /// Устройство применяется до старта движка; если движок уже прогрет, он пересобирается,
    /// поэтому вызывать нужно вне записи — перед `prepare()`/`start()`.
    public func setInputDevice(uid: String?) {
        guard uid != inputDeviceUID else { return }
        inputDeviceUID = uid
        guard tapInstalled || engine.isRunning else { return }  // применится при следующем старте
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            converter = nil
        }
        do {
            try startEngine()
        } catch {
            logger.error("Переключение микрофона не удалось: \(error.localizedDescription, privacy: .public)")
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

    /// Останавливает движок и освобождает микрофон (гаснет индикатор записи).
    /// Безопасно вызывать повторно; после `teardown()` `prepare()` снова поднимает движок.
    public func teardown() {
        lock.withLock {
            isRecording = false
            chunkHandler = nil
            pending.removeAll(keepingCapacity: false)
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        converter = nil
    }

    // MARK: - Движок

    private func startEngine() throws {
        if !tapInstalled {
            // Устройство ввода меняется только на остановленном движке (аудиоюнит должен быть
            // неинициализирован), поэтому любая пересборка tap-а идёт через stop().
            if engine.isRunning {
                engine.stop()
            }
            applyInputDevice()
            try installTap()
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Ставит выбранный микрофон на аудиоюнит входного узла. Только при остановленном движке.
    private func applyInputDevice() {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        let resolved = inputDeviceUID.flatMap { AudioDeviceList.device(uid: $0)?.id }
        guard var deviceID = resolved ?? AudioDeviceList.defaultInputDeviceID() else { return }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.error("Не удалось выбрать микрофон \(deviceID, privacy: .public): статус \(status, privacy: .public)")
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
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            reportConversionFailure("не удалось выделить буфер на \(capacity) сэмплов")
            return nil
        }

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
        guard status != .error, let channel = output.floatChannelData else {
            reportConversionFailure(error?.localizedDescription ?? "статус \(status.rawValue)")
            return nil
        }
        conversionFailureLogged = false
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Пишет в stderr одну строку на серию сбоев: tap приходит ~12 раз в секунду,
    /// иначе поток лога забьётся повторами.
    private func reportConversionFailure(_ reason: String) {
        guard !conversionFailureLogged else { return }
        conversionFailureLogged = true
        FileHandle.standardError.write(Data("AudioRecorder: конвертация в 16 кГц не удалась — \(reason)\n".utf8))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return min(1, meanSquare.squareRoot())
    }
}
