import AppKit
import Combine
import Foundation
import OSLog

/// Единственный канал прогресса и ошибок конвейера: UI подписан на `DictationController.state`.
public enum DictationState: Sendable, Equatable {
    case idle
    /// Доля скачанного/загрузки модели, 0...1.
    case preparingModel(Double)
    case recording(live: String, level: Float)
    case transcribing
    case cleaning
    case inserted
    /// Текст вставлен, но с оговоркой (без AI-чистки / только в буфер обмена).
    case degraded(String)
    case error(String)
}

public enum DictationError: LocalizedError, Sendable {
    case noSpeech

    public var errorDescription: String? {
        "речь не обнаружена"
    }
}

/// Сериализует распознавание: WhisperKit-инстанс не потокобезопасен, а live-превью и
/// финальный проход приходят из разных задач. Актор реентерабелен (на `await` он
/// освобождается), поэтому вызовы выстроены в цепочку задач — как в `VadGate.feedStream`.
actor EngineGate {
    private let engine: TranscriptionEngine
    private var inFlight: Task<String, Error>?

    init(_ engine: TranscriptionEngine) {
        self.engine = engine
    }

    /// Загрузка модели идёт мимо цепочки: она не трогает уже прогретый инстанс,
    /// а `WhisperEngine` сам склеивает параллельные `prepare`.
    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        try await engine.prepare(language: language, onState: onState)
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        let previous = inFlight
        let task = Task { [self] in
            _ = try? await previous?.value
            return try await run(samples, language: language, prompt: prompt)
        }
        // Регистрация синхронна: между чтением и записью `inFlight` нет ни одного await.
        inFlight = task
        return try await task.value
    }

    private func run(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        try await engine.transcribe(samples, language: language, prompt: prompt)
    }
}

/// Минимальный WAV: 16-bit PCM mono. Нужен только для бэкапа последней записи.
public enum WavEncoder {
    public static func encode(_ samples: [Float], sampleRate: Int = Int(AudioRecorder.sampleRate)) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)

        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        put32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        put32(16)                                       // размер fmt-чанка
        put16(1)                                        // PCM без сжатия
        put16(1)                                        // моно
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * bytesPerSample))      // байт в секунду
        put16(UInt16(bytesPerSample))                   // выравнивание блока
        put16(16)                                       // бит на сэмпл

        data.append(contentsOf: Array("data".utf8))
        put32(UInt32(dataSize))
        for sample in samples {
            put16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_767)))
        }
        return data
    }
}

/// Конвейер диктовки: запись → VAD → Whisper → словарь → GPT → вставка.
@MainActor
public final class DictationController: ObservableObject {

    /// Период live-превью и минимум аудио для него (1 c).
    private static let previewInterval: TimeInterval = 1.2
    private static let previewMinSamples = Int(AudioRecorder.sampleRate)
    /// Сколько держим финальное состояние перед возвратом в `.idle`.
    private static let insertedLinger: TimeInterval = 1.5
    private static let degradedLinger: TimeInterval = 2.5
    private static let errorLinger: TimeInterval = 2
    /// Сообщение действий меню (перевод последней диктовки) поверх простоя.
    private static let flashLinger: TimeInterval = 2
    /// Через столько простоя отпускаем микрофон (гаснет индикатор записи).
    private static let micReleaseDelay: TimeInterval = 60

    /// Бэкап последней записи — на случай, если вставка не дошла до приложения.
    private static let backupURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriber/last-recording.wav")

    @Published public private(set) var state: DictationState = .idle
    /// Последняя диктовка после слоя 2 и GPT-чистки, до перевода (для действий меню).
    @Published public private(set) var lastOriginal: String?
    /// Английский перевод последней диктовки: вставленный или сделанный по запросу из меню.
    @Published public private(set) var lastTranslation: String?

    private let gate: EngineGate
    private let dictionary: UserDictionary
    private let settings: AppSettings
    private let history: HistoryStore
    private let recorder = AudioRecorder()
    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "Dictation")

    private var vad: VadGate?
    private var buffer: [Float] = []
    private var live = ""
    private var level: Float = 0
    private var sessionLanguage: Language = .ru
    /// Старт асинхронный, а состояние меняется только в его конце — флаг закрывает
    /// окно, в котором второй хоткей запустил бы вторую запись.
    private var isStarting = false

    private var chunks: AsyncStream<[Float]>.Continuation?
    private var vadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var micReleaseTask: Task<Void, Never>?
    private var deviceSubscription: AnyCancellable?

    public init(engine: TranscriptionEngine, dictionary: UserDictionary, settings: AppSettings) {
        self.gate = EngineGate(engine)
        self.dictionary = dictionary
        self.settings = settings
        self.history = .shared

        recorder.setInputDevice(uid: settings.inputDeviceUID)
        // Текущее значение уже применено выше — подписка нужна только на последующие смены.
        deviceSubscription = settings.$inputDeviceUID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in
                MainActor.assumeIsolated { self?.recorder.setInputDevice(uid: uid) }
            }
    }

    // MARK: - Вход хоткеев

    public func toggle() {
        switch state {
        case .recording:
            stopAndProcess()
        case .idle, .inserted, .degraded, .error:
            begin()
        case .preparingModel, .transcribing, .cleaning:
            break  // конвейер занят — хоткей игнорируем
        }
    }

    public func switchLanguage() {
        settings.language = settings.language == .ru ? .uk : .ru
    }

    /// Прогон файла для CLI: VAD-обрезка → Whisper → словарь → (опционально) GPT. Без вставки и истории.
    public func process(fileSamples: [Float], language: Language, useGPT: Bool) async throws -> String {
        defer { state = .idle }

        try await gate.prepare(language: language) { [weak self] modelState in
            Task { @MainActor in self?.apply(modelState) }
        }
        let vad = try await ensureVad()
        guard let speech = try await vad.trimmed(fileSamples) else { throw DictationError.noSpeech }

        let entries = dictionary.entries
        state = .transcribing
        let raw = try await gate.transcribe(
            speech,
            language: language,
            prompt: PromptBuilder.initialPrompt(entries: entries, language: language)
        )
        let text = ReplacementEngine.apply(raw, entries: entries)
        guard useGPT else { return text }

        state = .cleaning
        return try await PostProcessor.cleanup(
            text: text,
            entries: entries,
            language: language,
            config: settings.gptConfig
        )
    }

    // MARK: - Запись

    private func begin() {
        guard !isStarting else { return }  // старт уже идёт — второй хоткей игнорируем
        isStarting = true

        idleTask?.cancel()
        idleTask = nil
        micReleaseTask?.cancel()
        micReleaseTask = nil
        // Дёшево и идемпотентно: если UID не менялся, вызов ничего не делает.
        recorder.setInputDevice(uid: settings.inputDeviceUID)
        recorder.prepare()  // движок поднимается заранее, чтобы старт записи был мгновенным

        let language = settings.language
        sessionLanguage = language
        Task {
            defer { isStarting = false }
            do {
                try await gate.prepare(language: language) { [weak self] modelState in
                    Task { @MainActor in self?.apply(modelState) }
                }
                try await startCapture(language: language)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func startCapture(language: Language) async throws {
        // Страховка от хвостов прошлой сессии: осиротевший цикл превью крутился бы вечно.
        previewTask?.cancel()
        previewTask = nil
        vadTask?.cancel()
        vadTask = nil
        chunks?.finish()
        chunks = nil

        let vad = try await ensureVad()
        await vad.resetStream()

        buffer.removeAll(keepingCapacity: true)
        live = ""
        level = 0

        let stream = AsyncStream<[Float]> { continuation in chunks = continuation }
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.updateLevel(value) }
        }

        // Состояние ставим до старта: чанки приходят сразу, а `append` фильтрует по нему.
        state = .recording(live: "", level: 0)
        do {
            try recorder.start { [weak self] chunk in
                Task { @MainActor in self?.append(chunk) }
            }
        } catch {
            chunks?.finish()
            chunks = nil
            recorder.onLevel = nil
            throw error
        }

        startVadLoop(stream: stream, vad: vad)
        startPreviewLoop(language: language)
    }

    private func append(_ chunk: [Float]) {
        guard case .recording = state else { return }
        buffer.append(contentsOf: chunk)
        chunks?.yield(chunk)
    }

    private func updateLevel(_ value: Float) {
        guard case .recording = state else { return }
        level = value
        state = .recording(live: live, level: value)
    }

    /// 2 с тишины после речи → автостоп.
    private func startVadLoop(stream: AsyncStream<[Float]>, vad: VadGate) {
        vadTask = Task { [weak self] in
            for await chunk in stream {
                guard let speechEnded = try? await vad.feedStream(chunk) else { continue }
                if speechEnded {
                    self?.autoStop()
                    return
                }
            }
        }
    }

    /// Live-превью: полный ре-декод накопленного буфера, следующий проход стартует
    /// только после завершения предыдущего (цикл последовательный).
    private func startPreviewLoop(language: Language) {
        let prompt = PromptBuilder.initialPrompt(entries: dictionary.entries, language: language)
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.previewInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard let samples = self.previewSamples() else { continue }
                guard let text = try? await self.gate.transcribe(samples, language: language, prompt: prompt) else {
                    continue
                }
                // Пока считали, запись могли остановить — в новую сессию не рисуем.
                guard !Task.isCancelled else { return }
                self.applyLive(text)
            }
        }
    }

    private func previewSamples() -> [Float]? {
        guard case .recording = state, buffer.count >= Self.previewMinSamples else { return nil }
        return buffer
    }

    private func applyLive(_ text: String) {
        guard case .recording = state else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        live = trimmed
        state = .recording(live: trimmed, level: level)
    }

    private func autoStop() {
        guard case .recording = state else { return }
        stopAndProcess()
    }

    private func stopAndProcess() {
        previewTask?.cancel()
        let preview = previewTask
        previewTask = nil
        chunks?.finish()
        chunks = nil
        vadTask?.cancel()
        vadTask = nil
        recorder.onLevel = nil

        let samples = recorder.stop()
        buffer.removeAll(keepingCapacity: false)
        let language = sessionLanguage
        state = .transcribing
        Task {
            // Отмена не прерывает уже начатый декод WhisperKit — дожидаемся его,
            // чтобы финальный проход не пересёкся с превью на одном инстансе.
            await preview?.value
            await runPipeline(samples: samples, language: language)
        }
    }

    // MARK: - Конвейер

    private func runPipeline(samples: [Float], language: Language) async {
        await writeBackup(samples)
        do {
            let vad = try await ensureVad()
            // Финал — всегда свежее распознавание обрезанной записи, превью не переиспользуем.
            guard let speech = try await vad.trimmed(samples) else { throw DictationError.noSpeech }

            let entries = dictionary.entries
            let raw = try await gate.transcribe(
                speech,
                language: language,
                prompt: PromptBuilder.initialPrompt(entries: entries, language: language)
            )
            var text = ReplacementEngine.apply(raw, entries: entries)
            var degradations: [String] = []
            let wantsTranslation = settings.translateToEnglish
            var translation: String?

            if settings.gptEnabled {
                state = .cleaning
                do {
                    // Перевод делает тот же вызов: GPT чистит текст и сразу отдаёт английский.
                    let processed = try await PostProcessor.cleanup(
                        text: text,
                        entries: entries,
                        language: language,
                        config: settings.gptConfig,
                        translateToEnglish: wantsTranslation
                    )
                    if wantsTranslation {
                        translation = processed
                    } else {
                        text = processed
                    }
                } catch {
                    // Слой 3 не обязателен: отдаём результат слоя 2 и говорим об этом.
                    degradations.append(
                        wantsTranslation
                            ? "без перевода: \(error.localizedDescription)"
                            : "без AI-чистки: \(error.localizedDescription)"
                    )
                    logger.error("GPT-слой не отработал: \(error.localizedDescription, privacy: .public)")
                }
            } else if wantsTranslation {
                degradations.append("без перевода")
            }

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DictationError.noSpeech
            }
            lastOriginal = text
            lastTranslation = translation

            let output = translation ?? text
            let outcome = await insert(output)
            history.add(output, language: language)
            removeBackup()

            if case .clipboardOnly(let reason) = outcome {
                degradations.append(Self.clipboardMessage(reason))
            }
            if degradations.isEmpty {
                state = .inserted
                scheduleIdle(after: Self.insertedLinger)
            } else {
                state = .degraded(degradations.joined(separator: "; "))
                scheduleIdle(after: Self.degradedLinger)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Последняя диктовка (действия меню)

    /// Кладёт последнюю диктовку (текст до перевода) в буфер обмена. Без вставки в приложение.
    public func copyLastOriginal() {
        guard let lastOriginal else { return }
        copyToClipboard(lastOriginal)
    }

    /// Кладёт в буфер английский перевод последней диктовки; готовый перевод берём из кэша.
    public func translateLastAndCopy() async {
        guard let original = lastOriginal else { return }
        if let lastTranslation {
            copyToClipboard(lastTranslation)
            return
        }
        do {
            let translated = try await PostProcessor.cleanup(
                text: original,
                entries: dictionary.entries,
                language: sessionLanguage,
                config: settings.gptConfig,
                translateToEnglish: true
            )
            lastTranslation = translated
            copyToClipboard(translated)
        } catch {
            logger.error("Перевод последней диктовки не удался: \(error.localizedDescription, privacy: .public)")
            flash("перевод не удался")
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Короткое сообщение поверх простоя: работающий конвейер не перебиваем.
    private func flash(_ message: String) {
        switch state {
        case .idle, .inserted, .degraded, .error:
            state = .degraded(message)
            scheduleIdle(after: Self.flashLinger)
        case .preparingModel, .recording, .transcribing, .cleaning:
            break
        }
    }

    /// `TextInserter.insert` синхронно спит 50 мс — уводим с главного потока.
    private func insert(_ text: String) async -> InsertOutcome {
        await Task.detached(priority: .userInitiated) { TextInserter.insert(text) }.value
    }

    private static func clipboardMessage(_ reason: String) -> String {
        switch reason {
        case "secure input": return "поле пароля — текст в буфере обмена"
        case "no accessibility": return "нет доступа к Универсальному доступу — текст в буфере обмена"
        default: return "текст только в буфере обмена (\(reason))"
        }
    }

    // MARK: - Состояние и ресурсы

    private func apply(_ modelState: ASRModelState) {
        switch modelState {
        case .downloading(let progress): state = .preparingModel(progress)
        case .loading: state = .preparingModel(1)
        case .notLoaded, .ready: break
        }
    }

    private func ensureVad() async throws -> VadGate {
        if let vad { return vad }
        state = .preparingModel(1)
        let created = try await VadGate()
        vad = created
        return created
    }

    private func fail(_ message: String) {
        state = .error(message)
        scheduleIdle(after: Self.errorLinger)
    }

    private func scheduleIdle(after seconds: TimeInterval) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.state = .idle
            self.scheduleMicRelease()
        }
    }

    /// Микрофон держим прогретым сразу после диктовки (следующая обычно рядом),
    /// но через минуту простоя отпускаем — индикатор записи не должен гореть вечно.
    private func scheduleMicRelease() {
        micReleaseTask?.cancel()
        micReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.micReleaseDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.recorder.teardown()
        }
    }

    /// Кодирование и запись WAV — вне главного потока: на длинной диктовке это сотни мс.
    private func writeBackup(_ samples: [Float]) async {
        let url = Self.backupURL
        let failure = await Task.detached(priority: .utility) { () -> String? in
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try WavEncoder.encode(samples).write(to: url, options: .atomic)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        if let failure {
            logger.error("Бэкап записи не сохранён: \(failure, privacy: .public)")
        }
    }

    private func removeBackup() {
        try? FileManager.default.removeItem(at: Self.backupURL)
    }
}
