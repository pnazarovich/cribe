import Foundation

/// Формат, в котором захват отдаёт звук конвейеру: 16 кГц mono Float32 чанками по 4096 сэмплов.
/// Одно место на оба захвата — `CaptureRecorder` (рабочий) и `AudioRecorder` (запасной).
public enum AudioCaptureFormat {
    /// Частота дискретизации, которую ждут VAD и Whisper.
    public static let sampleRate: Double = 16_000
    /// Размер чанка для Silero VAD — 4096 сэмплов (256 мс).
    public static let chunkSize = 4096

    /// Сколько сэмплов в секундах записи.
    public static func samples(seconds: Double) -> Int {
        Int(sampleRate * seconds)
    }

    /// Короче полусекунды судить о тишине на входе нельзя: микрофон мог только открыться.
    public static let silenceVerdictMinimumSamples = samples(seconds: 0.5)

    /// Пик записанного ниже этого — не «человек молчал», а вход не отдаёт сигнал вовсе:
    /// −70 dBFS тише шума любого живого микрофона (у мёртвого HFP-входа гарнитуры пик 0.0001).
    /// Порог общий на всё ядро: по нему же `AudioNormalizer` решает, что усиливать нечего, —
    /// второго порога тишины в приложении быть не должно.
    public static let silenceThreshold: Float = 0.0003
}

/// Поверхность захвата микрофона, на которую опирается `DictationController`.
///
/// Реализаций две: `CaptureRecorder` (AVCaptureSession, по умолчанию) и `AudioRecorder`
/// (AVAudioEngine, запасной путь). Протокол нужен ровно для того, чтобы конвейер не знал,
/// какая из них работает, и чтобы тесты подставляли заглушку вместо живого микрофона.
public protocol AudioCapturing: AnyObject {
    /// Уровень сигнала (RMS 0…1) на каждый блок захвата, ~10 Гц. Речь обычно даёт 0.02…0.2.
    var onLevel: (@Sendable (Float) -> Void)? { get set }
    /// Захват сорвался на ходу: микрофон не отдал ни одного блока, устройство исчезло,
    /// сессия упала. Строка — готовое сообщение пользователю.
    var onFailure: (@Sendable (String) -> Void)? { get set }
    /// Записанное — цифровая тишина (пик ниже −70 dBFS). Так выглядит мёртвый вход
    /// (HFP-микрофон гарнитуры), а не молчащий человек: у живого микрофона есть шум.
    var capturedSilence: Bool { get }
    /// Снимок уже записанного, не останавливая запись: префикс того, что вернёт `stop()`.
    var capturedSamples: [Float] { get }
    /// Длина уже записанного. Отдельно от `capturedSamples`: снимок массива стоит копии
    /// по записи на аудиопотоке, а опрашивать длину нужно часто.
    var capturedSampleCount: Int { get }

    /// Выбирает микрофон по UID (`nil` — системный по умолчанию).
    func setInputDevice(uid: String?)
    /// Прогрев: поднимает захват заранее, чтобы старт записи был мгновенным.
    func prepare()
    /// Начинает запись. `onChunk` вызывается с аудиопотока чанками по 4096 сэмплов 16 кГц mono.
    func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws
    /// Останавливает запись и возвращает весь записанный буфер. Захват остаётся прогретым.
    func stop() -> [Float]
    /// Освобождает микрофон (гаснет индикатор записи). После `teardown()` `prepare()` поднимает заново.
    func teardown()
}
