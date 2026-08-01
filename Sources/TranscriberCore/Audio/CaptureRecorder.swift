import Accelerate
import AVFoundation
import Foundation
import OSLog

/// Захват микрофона на AVCaptureSession: CMSampleBuffer → AVAudioConverter → 16 кГц mono Float32.
///
/// Почему не AVAudioEngine: выбрать конкретный микрофон там можно только записью
/// `kAudioOutputUnitProperty_CurrentDevice` в аудиоюнит, а эта запись идёт мимо бухгалтерии
/// движка — форматы разъезжаются, tap молча замолкает, пин не переживает пересборку движка.
/// У AVCaptureSession выбор устройства — штатная операция: сессия сама согласует формат
/// с устройством, поэтому вся машинерия вокруг уведомлений о смене конфигурации не нужна.
///
/// Публичный API вызывается с главного потока, сэмплы приходят на `sampleQueue` —
/// общий буфер закрыт `lock`, состояние конвертера живёт только на `sampleQueue`.
public final class CaptureRecorder: NSObject, AudioCapturing, AVCaptureAudioDataOutputSampleBufferDelegate {

    public var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { levelHandler } }
        set { lock.withLock { levelHandler = newValue } }
    }

    public var onFailure: (@Sendable (String) -> Void)? {
        get { lock.withLock { failureHandler } }
        set { lock.withLock { failureHandler = newValue } }
    }

    /// Пик записанного ниже этого — не «человек молчал», а вход не отдаёт сигнал вовсе:
    /// −70 dBFS тише шума любого живого микрофона (у мёртвого HFP-входа гарнитуры пик 0.0001).
    private static let silenceThreshold: Float = 0.0003
    /// Сколько ждём первый блок после старта записи. Не пришло ничего — микрофон мёртв,
    /// и об этом надо сказать сразу, а не отдавать «речь не обнаружена» через минуту диктовки.
    private static let watchdogTimeout: TimeInterval = 2

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioCaptureFormat.sampleRate,
        channels: 1,
        interleaved: false
    )!  // параметры константны и валидны

    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "CaptureRecorder")
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    /// Своя последовательная очередь доставки: делить её с чем-либо нельзя — блок конвертации
    /// идёт по расписанию аудио, и любой чужой долгий блок означал бы пропуск сэмплов.
    private let sampleQueue = DispatchQueue(label: "online.nazarovych.transcriber.capture")
    private let lock = NSLock()

    // Под lock:
    private var samples: [Float] = []
    private var pending: [Float] = []
    private var chunkHandler: (@Sendable ([Float]) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var failureHandler: (@Sendable (String) -> Void)?
    private var isRecording = false
    /// Номер записи: сторож первого блока, опоздавший к следующей записи, не должен её ронять.
    private var recordingGeneration = 0
    /// Пришёл ли хоть один блок с начала текущей записи — это и проверяет сторож.
    private var receivedBuffer = false
    /// Сессию прервала система (микрофон забрал кто-то другой): сторожу тут ругаться не на что.
    private var isInterrupted = false

    // Только главный поток:
    private var deviceInput: AVCaptureDeviceInput?
    /// UID выбранного микрофона; nil — системный по умолчанию. Само устройство резолвится
    /// в момент сборки сессии, поэтому смена системного входа на простое ничего не требует.
    ///
    /// Persistence по UID. У Bluetooth-устройств UID меняется при повторном спаривании —
    /// VoiceInk держит на этот случай запасной ключ `kAudioDevicePropertyModelUID`;
    /// нам это пока не нужно (выбор пересоздаётся из меню), но путь известен.
    private var inputDeviceUID: String?
    private var sessionObservers: [NSObjectProtocol] = []

    // Только sampleQueue:
    private var converter: AVAudioConverter?
    private var conversionFailureLogged = false

    public override init() {
        super.init()
        // macOS честно отрабатывает `audioSettings` (в отличие от iOS): просим у сессии
        // сразу целевой формат, и ресемплинг делает она сама. Конвертер ниже всё равно
        // остаётся — если сессия отдаст своё, он приведёт к 16 кГц mono, как и раньше.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioCaptureFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        observeSession()
    }

    deinit {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Сессия сама сообщает о своих бедах — своей машинерии слежения за устройствами
    /// не нужно вовсе. Ошибку времени выполнения она шлёт и когда устройство исчезло
    /// посреди записи; прерывание (кто-то забрал микрофон) сессия гасит сама и сама же
    /// поднимается обратно, поэтому нам остаётся сообщить о нём и не мешать.
    private func observeSession() {
        let center = NotificationCenter.default
        sessionObservers.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] note in
                self?.handleRuntimeError(note)
            }
        )
        sessionObservers.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.logger.error("Захват прерван системой")
                self.lock.withLock { self.isInterrupted = true }
                self.reportFailure("захват прерван системой")
            }
        )
        sessionObservers.append(
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.logger.info("Прерывание захвата закончилось")
                self.lock.withLock { self.isInterrupted = false }
            }
        )
    }

    // MARK: - Публичный API

    /// Смена устройства: сессию останавливаем, вход подменяем, поднимаем заново — этот путь
    /// AVCaptureSession поддерживает сама, никакой пересборки форматов руками не нужно.
    /// Вызов до первого `prepare()` только запоминает UID: устройство резолвится на старте.
    public func setInputDevice(uid: String?) {
        guard uid != inputDeviceUID else { return }
        inputDeviceUID = uid
        guard deviceInput != nil else { return }  // сессии ещё нет — применится на старте

        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        attachInput()
        if wasRunning { session.startRunning() }
    }

    public func prepare() {
        startSession()
    }

    public func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws {
        let generation: Int = lock.withLock {
            samples.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
            chunkHandler = onChunk
            isRecording = true
            receivedBuffer = false
            recordingGeneration += 1
            return recordingGeneration
        }
        startSession()
        guard session.isRunning else {
            lock.withLock {
                isRecording = false
                chunkHandler = nil
            }
            throw AudioRecorderError.noInputDevice
        }
        startWatchdog(generation: generation)
    }

    /// Сторож первого блока: сессия может честно «работать» и не отдавать ни одного буфера
    /// (устройство исчезло между сборкой и стартом, вход занят). Молчать об этом нельзя —
    /// иначе диктовка кончится бессмысленным «речь не обнаружена».
    private func startWatchdog(generation: Int) {
        sampleQueue.asyncAfter(deadline: .now() + Self.watchdogTimeout) { [weak self] in
            self?.checkFirstBuffer(generation: generation)
        }
    }

    private func checkFirstBuffer(generation: Int) {
        enum Verdict { case ignore, dead, silent, healthy }
        let verdict: Verdict = lock.withLock {
            guard isRecording, generation == recordingGeneration else { return .ignore }
            if isInterrupted { return .ignore }  // прерывание уже отправило свою ошибку
            guard receivedBuffer else { return .dead }
            return peakLocked() < Self.silenceThreshold ? .silent : .healthy
        }
        switch verdict {
        case .ignore, .healthy:
            return
        case .dead:
            logger.error("Микрофон не отдал ни одного блока за \(Self.watchdogTimeout, privacy: .public) с")
            reportFailure("микрофон не отдаёт звук — выберите другой вход")
        case .silent:
            // Не обрываем: тихая комната бывает. Но в поле именно эта строка объясняет,
            // почему диктовка кончилась ничем — вход отдаёт цифровую тишину.
            logger.error("Вход отдаёт тишину (пик ниже −70 dBFS) — похоже на мёртвый микрофон")
        }
    }

    private func reportFailure(_ message: String) {
        let handler = lock.withLock { failureHandler }
        handler?(message)
    }

    public var capturedSampleCount: Int {
        lock.withLock { samples.count }
    }

    public var capturedSamples: [Float] {
        lock.withLock { samples }
    }

    public var capturedSilence: Bool {
        lock.withLock { !samples.isEmpty && peakLocked() < Self.silenceThreshold }
    }

    /// Пик модуля по всему буферу. Только под `lock` и без копии массива: буфер длинной
    /// диктовки — это мегабайты, а зовут это раз на диктовку.
    private func peakLocked() -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak
    }

    public func stop() -> [Float] {
        lock.withLock {
            isRecording = false
            chunkHandler = nil
            pending.removeAll(keepingCapacity: true)
            return samples
        }
    }

    /// Останавливает сессию и отцепляет вход. Отцепляем намеренно: следующий `prepare()`
    /// заново резолвит устройство, поэтому смена системного микрофона на простое (подключили
    /// наушники) подхватывается сама, без единой подписки на маршрут.
    public func teardown() {
        lock.withLock {
            isRecording = false
            chunkHandler = nil
            pending.removeAll(keepingCapacity: false)
        }
        if session.isRunning { session.stopRunning() }
        detachInput()
    }

    // MARK: - Сессия

    private func startSession() {
        guard !session.isRunning else { return }
        if deviceInput == nil { attachInput() }
        guard deviceInput != nil else { return }
        session.startRunning()
    }

    /// Ставит в сессию вход выбранного (или системного) микрофона. Вызывать только на
    /// остановленной сессии — см. `setInputDevice`.
    private func attachInput() {
        guard let device = resolveDevice() else {
            logger.error("Микрофон не найден: uid \(self.inputDeviceUID ?? "по умолчанию", privacy: .public)")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if let deviceInput {
                session.removeInput(deviceInput)
                self.deviceInput = nil
            }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                logger.error("Сессия не приняла микрофон \(device.uniqueID, privacy: .public)")
                return
            }
            session.addInput(input)
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    logger.error("Сессия не приняла выход аудио")
                    return
                }
                session.addOutput(output)
            }
            session.commitConfiguration()
            deviceInput = input
            // Тихий отказ микрофона в поле диагностируется только по этой строке.
            logger.info(
                "Вход подключён: \(device.localizedName, privacy: .public) [\(device.uniqueID, privacy: .public)]"
            )
        } catch {
            logger.error("Не удалось открыть микрофон: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func detachInput() {
        guard let deviceInput else { return }
        session.beginConfiguration()
        session.removeInput(deviceInput)
        session.commitConfiguration()
        self.deviceInput = nil
    }

    /// Цепочка выбора: явный UID → системный по умолчанию → первый попавшийся вход.
    /// У аудиоустройств `uniqueID` совпадает с UID из CoreAudio — тем самым, что лежит
    /// в настройках и в списке меню. Устройство пропало из системы (отключили гарнитуру) —
    /// падаем на следующее звено: молчать из-за исчезнувшего выбора нельзя.
    private func resolveDevice() -> AVCaptureDevice? {
        if let uid = inputDeviceUID {
            if let device = AVCaptureDevice(uniqueID: uid) { return device }
            logger.error("Выбранный микрофон \(uid, privacy: .public) пропал — беру системный")
        }
        if let device = AVCaptureDevice.default(for: .audio) { return device }
        logger.error("Системного микрофона нет — беру первый из списка")
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.first
    }

    /// Устройство исчезло посреди записи (выдернули USB, отвалился Bluetooth): сессия сама
    /// сообщает об этом ошибкой. Останавливаемся аккуратно — записанное до сбоя остаётся
    /// в буфере, и обычный `stop()` конвейера его заберёт. Вход отцепляем: следующий старт
    /// соберёт сессию заново, по живым устройствам.
    private func handleRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        logger.error("Сессия захвата упала: \(error?.localizedDescription ?? "неизвестная ошибка", privacy: .public)")
        if session.isRunning { session.stopRunning() }
        detachInput()
        reportFailure("микрофон отключился")
    }

    // MARK: - Аудиопоток

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let converted = convert(sampleBuffer), !converted.isEmpty else { return }

        var chunks: [[Float]] = []
        var chunkSink: (@Sendable ([Float]) -> Void)?
        var levelSink: (@Sendable (Float) -> Void)?

        lock.withLock {
            guard isRecording else { return }
            receivedBuffer = true
            samples.append(contentsOf: converted)
            pending.append(contentsOf: converted)
            while pending.count >= AudioCaptureFormat.chunkSize {
                chunks.append(Array(pending.prefix(AudioCaptureFormat.chunkSize)))
                pending.removeFirst(AudioCaptureFormat.chunkSize)
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

    private func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: asbd)
        else {
            reportConversionFailure("формат буфера не разобран")
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        input.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: input.mutableAudioBufferList
        )
        guard status == noErr else {
            reportConversionFailure("копирование PCM не удалось (статус \(status))")
            return nil
        }
        guard let converter = converter(for: inputFormat) else {
            reportConversionFailure("нет конвертера \(inputFormat.sampleRate) Гц → 16 кГц")
            return nil
        }
        return resample(input, with: converter)
    }

    /// Конвертер живёт долго и ровно один на формат: ресемплер держит внутреннее состояние
    /// (фазу и хвост фильтра), и пересоздание на каждом буфере рвало бы сигнал на стыках.
    /// Формат меняется только вместе с устройством — тогда конвертер и правда нужен новый.
    private func converter(for format: AVAudioFormat) -> AVAudioConverter? {
        if let converter, converter.inputFormat == format { return converter }
        guard let created = AVAudioConverter(from: format, to: Self.targetFormat) else { return nil }
        converter = created
        logger.info(
            """
            Конвертер собран: \(format.sampleRate, privacy: .public) Гц, \
            \(format.channelCount, privacy: .public) кан. → 16000 Гц mono
            """
        )
        return created
    }

    /// Забираем из конвертера всё, что он готов отдать: `.haveData` означает «выходной буфер
    /// заполнен целиком, может быть ещё» — если на этом остановиться, остаток уедет в
    /// следующий вызов и запись будет короче реального времени.
    private func resample(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [Float]? {
        let ratio = Self.targetFormat.sampleRate / input.format.sampleRate
        // Запас сверх пропорции: ресемплер отдаёт хвост предыдущего буфера вместе с текущим.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        var supplied = false
        var converted: [Float] = []

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
                reportConversionFailure("не удалось выделить буфер на \(capacity) сэмплов")
                return nil
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error {
                reportConversionFailure(error?.localizedDescription ?? "статус \(status.rawValue)")
                return nil
            }
            if let channel = output.floatChannelData, output.frameLength > 0 {
                converted.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            guard status == .haveData, output.frameLength > 0 else { break }
        }
        conversionFailureLogged = false
        return converted
    }

    /// Одна строка на серию сбоев: буферы приходят десятки раз в секунду, иначе лог забьётся
    /// повторами. Пишем в os_log, а не в stderr: у собранного .app stderr никто не читает.
    private func reportConversionFailure(_ reason: String) {
        guard !conversionFailureLogged else { return }
        conversionFailureLogged = true
        logger.error("Конвертация в 16 кГц не удалась — \(reason, privacy: .public)")
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return min(1, meanSquare.squareRoot())
    }
}
