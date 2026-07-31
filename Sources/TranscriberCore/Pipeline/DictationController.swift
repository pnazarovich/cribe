import AppKit
import Combine
import Foundation
import OSLog

/// Единственный канал прогресса и ошибок конвейера: UI подписан на `DictationController.state`.
public enum DictationState: Sendable, Equatable {
    case idle
    /// Доля скачанного/загрузки модели, 0...1.
    case preparingModel(Double)
    /// `live` всегда пуст: живого превью в панели больше нет, но форма кейса сохранена
    /// ради совместимости с внешним кодом, который на него сопоставляется.
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

/// Сериализует распознавание: WhisperKit-инстанс не потокобезопасен, а вызовы могут прийти
/// из разных задач. Актор реентерабелен (на `await` он освобождается), поэтому вызовы
/// выстроены в цепочку задач — как в `VadGate.feedStream`.
actor EngineGate {
    private let engine: TranscriptionEngine
    /// Хвост цепочки: только «дождаться предыдущего», без его результата — так в одну
    /// очередь встают проходы с разными типами результата (текст и сегменты).
    private var inFlight: Task<Void, Never>?

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
            await previous?.value
            return try await run(samples, language: language, prompt: prompt)
        }
        chain(task)
        return try await task.value
    }

    func transcribeSegments(_ samples: [Float], language: Language, prompt: String) async throws -> [ASRSegment] {
        let previous = inFlight
        let task = Task { [self] in
            await previous?.value
            return try await runSegments(samples, language: language, prompt: prompt)
        }
        chain(task)
        return try await task.value
    }

    /// Регистрация синхронна: между чтением и записью `inFlight` нет ни одного await.
    /// Ошибку прохода цепочка глотает — она уже уехала тому, кто этот проход заказал.
    private func chain<T>(_ task: Task<T, Error>) {
        inFlight = Task { _ = try? await task.value }
    }

    private func run(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        try await engine.transcribe(samples, language: language, prompt: prompt)
    }

    private func runSegments(
        _ samples: [Float],
        language: Language,
        prompt: String
    ) async throws -> [ASRSegment] {
        try await engine.transcribeSegments(samples, language: language, prompt: prompt)
    }
}

/// Склейка подтверждённой фоном части диктовки с хвостом, распознанным на стопе.
/// Хвост берётся с нахлёстом назад, поэтому на стыке почти всегда есть общие слова —
/// их надо схлопнуть, а не продублировать.
enum StreamingMerge {
    /// Сколько слов на стыке максимум ищем: полсекунды речи — это 1–3 слова, запас с лихвой.
    private static let maxOverlapWords = 12

    /// Что из прохода можно считать устоявшимся: все сегменты, кроме последнего — его Whisper
    /// почти всегда переписывает на следующем проходе, когда слышит конец фразы.
    /// `nil` — подтверждать нечего (сегментов меньше двух).
    static func confirmed(from segments: [ASRSegment]) -> (text: String, endSample: Int)? {
        let stable = segments.dropLast()
        guard let last = stable.last else { return nil }
        return (
            stable.map(\.text).filter { !$0.isEmpty }.joined(separator: " "),
            Int(last.end * AudioRecorder.sampleRate)
        )
    }

    static func merge(confirmed: String, tail: String) -> String {
        let head = words(confirmed)
        let rest = words(tail)
        guard !head.isEmpty else { return rest.joined(separator: " ") }
        guard !rest.isEmpty else { return head.joined(separator: " ") }

        // Ищем самый длинный общий стык: совпадение в одно слово («и», «в») бывает случайным,
        // длинное — нет, поэтому идём от длинных к коротким и берём первое же.
        for length in stride(from: min(maxOverlapWords, head.count, rest.count), through: 1, by: -1) {
            guard head.suffix(length).map(normalized) == rest.prefix(length).map(normalized) else { continue }
            return (head + rest.dropFirst(length)).joined(separator: " ")
        }
        // Стык не нашёлся — терять слова нельзя, поэтому просто склеиваем.
        return (head + rest).joined(separator: " ")
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Между проходами гуляют регистр и пунктуация («привет,» против «Привет»), поэтому
    /// сравниваем очищенные формы, а в результат кладём слова как есть.
    private static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
    }
}

/// Гейт коротких диктовок. На «ок» или «да, давай» GPT-чистка не меняет ничего, но стоит
/// целого круга к модели — а именно короткие команды и диктуют, когда важна скорость.
/// Перевод исключение: его делает тот же вызов, поэтому с включённым переводом слой 3
/// обязателен всегда.
enum ShortDictation {
    static func skipsGPT(text: String, enabled: Bool, wordLimit: Int, translating: Bool) -> Bool {
        guard enabled, !translating else { return false }
        return wordCount(text) <= wordLimit
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
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

    /// Потоковая финализация. Фоновый проход стартует не раньше, чем через `rollingGap`
    /// после конца предыдущего, и только если с прошлого прохода записалось ещё
    /// `rollingGrowth` звука — иначе проходы шли бы сплошняком без нового материала.
    private static let rollingGap: TimeInterval = 0.5
    private static let rollingPoll: TimeInterval = 0.1
    private static let rollingGrowth = Int(AudioRecorder.sampleRate * 2)
    /// Нахлёст хвоста назад: даёт склейке общие слова на стыке.
    private static let tailOverlap = Int(AudioRecorder.sampleRate * 0.5)
    /// Короче этого потоковый путь не включаем: полный проход и так быстрый,
    /// а лишний риск на коротких диктовках не окупается.
    private static let streamingMinSamples = Int(AudioRecorder.sampleRate * 6)

    /// Сколько держим финальное состояние перед возвратом в `.idle`.
    private static let insertedLinger: TimeInterval = 1.5
    private static let degradedLinger: TimeInterval = 2.5
    private static let errorLinger: TimeInterval = 2
    /// Сообщение действий меню (перевод последней диктовки) поверх простоя.
    private static let flashLinger: TimeInterval = 2
    /// Через столько простоя отпускаем микрофон (гаснет индикатор записи). Пересборка
    /// движка стоит ~150 мс — это дешевле, чем оранжевая точка, висящая после вставки:
    /// горящий индикатор читается как «микрофон не выключается».
    private static let micReleaseDelay: TimeInterval = 0.5

    /// Бэкап последней записи — на случай, если вставка не дошла до приложения.
    private static let backupURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriber/last-recording.wav")

    @Published public private(set) var state: DictationState = .idle
    /// Последняя диктовка после слоя 2 и GPT-чистки, до перевода (для действий меню).
    @Published public private(set) var lastOriginal: String?
    /// Английский перевод последней диктовки: вставленный или сделанный по запросу из меню.
    @Published public private(set) var lastTranslation: String?
    /// Язык идущей диктовки. Переключение языка на живой записи меняет настройку, но не сессию —
    /// UI показывает отсюда, чтобы флаг не врал про то, чем на самом деле распознаётся речь.
    /// `nil` — сессии нет, показываем `settings.language`.
    @Published public private(set) var activeSessionLanguage: Language?

    private let gate: EngineGate
    private let dictionary: UserDictionary
    private let settings: AppSettings
    private let history: HistoryStore
    private let recorder = AudioRecorder()
    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "Dictation")

    private var vad: VadGate?
    private var sessionLanguage: Language = .ru
    /// Язык, на котором распознана `lastOriginal`: перевод из меню должен идти с него,
    /// а не с языка, который к тому моменту стоит в настройках.
    private var lastOriginalLanguage: Language = .ru
    /// Старт асинхронный, а состояние меняется только в его конце — флаг закрывает
    /// окно, в котором второй хоткей запустил бы вторую запись.
    private var isStarting = false
    /// Второй хоткей на `.preparingModel` отменяет сессию. Саму загрузку прервать нельзя
    /// (WhisperKit её не отменяет) — она спокойно дойдёт до кэша, но запись не начнётся.
    private var pendingCancel = false

    /// Подтверждённая часть диктовки: все сегменты последнего фонового прохода, кроме
    /// последнего (его следующий проход почти всегда переписывает), и конец последнего
    /// подтверждённого сегмента в сэмплах от начала записи.
    private var confirmedText = ""
    private var confirmedEndSample = 0
    /// Фоновый проход упал — на этой сессии потоковый путь выключен.
    private var rollingFailed = false
    /// Язык переключили прямо на записи — фоновые проходы и хвост могли бы разъехаться.
    private var languageSwitchedDuringSession = false
    /// Длина буфера на момент запуска последнего фонового прохода.
    private var rollingPassSamples = 0
    /// Промпт сессии: фоновые проходы и финал обязаны идти с одним биасингом, иначе
    /// подтверждённая часть и хвост распознаны по-разному и склейка врёт.
    private var sessionPrompt = ""

    private var chunks: AsyncStream<[Float]>.Continuation?
    private var vadTask: Task<Void, Never>?
    private var rollingTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var micReleaseTask: Task<Void, Never>?

    public init(engine: TranscriptionEngine, dictionary: UserDictionary, settings: AppSettings) {
        self.gate = EngineGate(engine)
        self.dictionary = dictionary
        self.settings = settings
        self.history = .shared
        // Микрофон намеренно не пиним: `AudioRecorder.setInputDevice` не вызывается нигде,
        // поэтому вход всегда системный по умолчанию. Пиннинг через AUHAL воевал с системой
        // (перебор устройства раз в секунду на BT-гарнитуре) и будет переделан отдельно.
    }

    // MARK: - Вход хоткеев

    public func toggle() {
        switch state {
        case .recording:
            stopAndProcess()
        case .idle, .inserted, .degraded, .error:
            begin()
        case .preparingModel:
            // Первая загрузка модели идёт минутами — хоткей отменяет сессию, а не ждёт впустую.
            pendingCancel = true
        case .transcribing, .cleaning:
            break  // конвейер занят — хоткей игнорируем
        }
    }

    public func switchLanguage() {
        // Язык сессии от этого не меняется (см. `activeSessionLanguage`), но потоковый путь
        // должен быть гарантированно однородным — на живой записи просто выключаем его.
        if case .recording = state { languageSwitchedDuringSession = true }
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
        pendingCancel = false  // отмена прошлой сессии новую не трогает

        idleTask?.cancel()
        idleTask = nil
        micReleaseTask?.cancel()
        micReleaseTask = nil
        prewarmGPT()

        let language = settings.language
        sessionLanguage = language
        activeSessionLanguage = language
        Task {
            defer { isStarting = false }
            do {
                try await gate.prepare(language: language) { [weak self] modelState in
                    Task { @MainActor in self?.apply(modelState) }
                }
                // Пока грузилась модель, хоткей нажали второй раз — сессия отменена.
                if pendingCancel {
                    cancelSession()
                    return
                }
                // Микрофон поднимаем только здесь: первая загрузка модели идёт минутами,
                // и всё это время индикатор записи гореть не должен.
                recorder.prepare()  // движок поднимается прямо перед стартом — запись начнётся мгновенно
                try await startCapture()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Пока идёт запись, соединение до GPT успевает установиться — POST чистки уходит
    /// в уже прогретый канал. Строго побочный эффект: результат не ждём, ошибки не смотрим,
    /// на состояние конвейера прогрев не влияет никак.
    private func prewarmGPT() {
        guard settings.gptEnabled else { return }
        let config = settings.gptConfig
        Task.detached(priority: .utility) { await GPTClient(config: config).prewarm() }
    }

    private func startCapture() async throws {
        // Страховка от хвостов прошлой сессии: осиротевший VAD-цикл крутился бы вечно.
        vadTask?.cancel()
        vadTask = nil
        rollingTask?.cancel()
        rollingTask = nil
        chunks?.finish()
        chunks = nil

        confirmedText = ""
        confirmedEndSample = 0
        rollingPassSamples = 0
        rollingFailed = false
        languageSwitchedDuringSession = false
        sessionPrompt = PromptBuilder.initialPrompt(
            entries: dictionary.entries,
            language: sessionLanguage
        )

        let vad = try await ensureVad()
        // Первый за запуск подъём VAD (CoreML/ANE) занимает секунды и снова показывает
        // `.preparingModel` — уже после того, как `begin()` проверил отмену. Хоткей,
        // нажатый в это окно, терять нельзя: иначе запись стартует вопреки отмене.
        if pendingCancel {
            cancelSession()
            return
        }
        await vad.resetStream()

        let stream = AsyncStream<[Float]> { continuation in chunks = continuation }
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.updateLevel(value) }
        }

        // Состояние ставим до старта: чанки приходят сразу, а `append` фильтрует по нему.
        state = .recording(live: "", level: 0)
        // Хвост чайма попадает в запись — VAD обрезает не-речь.
        if settings.soundsEnabled { SoundPlayer.shared.playStart() }
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
        startRollingLoop(language: sessionLanguage)
    }

    /// Фоновая финализация: пока идёт запись, большая модель переписывает весь накопленный
    /// буфер и подтверждает всё, кроме последнего сегмента. К стопу остаётся распознать
    /// только хвост, а не десять секунд заново.
    ///
    /// Проходы стоят в общей очереди `EngineGate` — WhisperKit-инстанс один, и финальный
    /// хвост всё равно дождётся идущего прохода. Никакого состояния UI цикл не трогает.
    private func startRollingLoop(language: Language) {
        let prompt = sessionPrompt
        rollingTask = Task { [weak self] in
            while true {
                guard let self, case .recording = self.state else { return }

                // До порога потокового пути проходы бессмысленны и вредны: короткая диктовка
                // всё равно пойдёт полным проходом, а идущий проход стоп обязан дождаться —
                // это была бы чистая потеря там, где скорость важнее всего.
                let samples = self.recorder.capturedSamples
                guard samples.count >= Self.streamingMinSamples,
                      samples.count - self.rollingPassSamples >= Self.rollingGrowth
                else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.rollingPoll * 1_000_000_000))
                    continue
                }
                self.rollingPassSamples = samples.count

                do {
                    let segments = try await self.gate.transcribeSegments(
                        samples,
                        language: language,
                        prompt: prompt
                    )
                    self.confirm(segments)
                } catch {
                    // Один упавший проход — и весь потоковый путь снят: финал пойдёт полным
                    // проходом, как раньше. Оптимизация не имеет права быть риском.
                    self.rollingFailed = true
                    self.logger.error(
                        "Фоновый проход не удался: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }

                // Передышку берём только на живой записи: стоп ждёт эту задачу, и лишний сон
                // после уже посчитанного прохода был бы прямой задержкой финала.
                guard case .recording = self.state else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.rollingGap * 1_000_000_000))
            }
        }
    }

    private func confirm(_ segments: [ASRSegment]) {
        // Назад не сдаём: перестройка сегментов может дать более короткий подтверждённый
        // префикс, и тогда честнее оставить прошлый результат — хвост всё равно длиннее.
        guard let pass = StreamingMerge.confirmed(from: segments),
              pass.endSample > confirmedEndSample
        else { return }
        confirmedEndSample = pass.endSample
        confirmedText = pass.text
    }

    private func append(_ chunk: [Float]) {
        guard case .recording = state else { return }
        chunks?.yield(chunk)
    }

    private func updateLevel(_ value: Float) {
        guard case .recording = state else { return }
        state = .recording(live: "", level: value)
    }

    /// 2 с тишины после речи → автостоп, если он включён в настройках.
    private func startVadLoop(stream: AsyncStream<[Float]>, vad: VadGate) {
        vadTask = Task { [weak self] in
            for await chunk in stream {
                guard let speechEnded = try? await vad.feedStream(chunk) else { continue }
                // Автостоп по умолчанию выключен: запись останавливает только повторный хоткей.
                // Кормить гейт при этом продолжаем — состояние стрима должно оставаться живым,
                // если автостоп включат посреди записи. Обрезка финального буфера идёт отдельно.
                guard speechEnded, self?.settings.autoStopEnabled == true else { continue }
                self?.autoStop()
                return
            }
        }
    }

    private func autoStop() {
        guard case .recording = state else { return }
        stopAndProcess()
    }

    private func stopAndProcess() {
        chunks?.finish()
        chunks = nil
        vadTask?.cancel()
        vadTask = nil
        // Отмена не прерывает идущий проход (он живёт своей задачей в `EngineGate`),
        // зато снимает передышку между проходами — иначе финал ждал бы её впустую.
        rollingTask?.cancel()
        recorder.onLevel = nil

        let samples = recorder.stop()
        if settings.soundsEnabled { SoundPlayer.shared.playStop() }
        let language = sessionLanguage
        state = .transcribing
        Task { await runPipeline(samples: samples, language: language) }
    }

    // MARK: - Конвейер

    private func runPipeline(samples: [Float], language: Language) async {
        // Бэкап уходит в фон и не ждётся: кодирование и запись WAV длинной диктовки —
        // это сотни миллисекунд ровно перед распознаванием, то есть чистая задержка.
        let backup = startBackup(samples)
        // Идущий фоновый проход обязателен к ожиданию: он и досчитывает подтверждённую часть,
        // и в любом случае занимает единственный инстанс WhisperKit.
        await rollingTask?.value
        rollingTask = nil
        do {
            let entries = dictionary.entries
            let raw: String
            if let streamed = await streamedTranscript(samples: samples, language: language) {
                raw = streamed
            } else {
                let vad = try await ensureVad()
                guard let speech = try await vad.trimmed(samples) else { throw DictationError.noSpeech }
                raw = try await gate.transcribe(speech, language: language, prompt: sessionPrompt)
            }
            var text = ReplacementEngine.apply(raw, entries: entries)
            var degradations: [String] = []
            let wantsTranslation = settings.translateToEnglish
            var translation: String?
            let skipsGPT = ShortDictation.skipsGPT(
                text: text,
                enabled: settings.skipGPTForShort,
                wordLimit: settings.shortDictationWordLimit,
                translating: wantsTranslation
            )

            if settings.gptEnabled, !skipsGPT {
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
                    // При переводе тем же вызовом теряется и чистка — говорим об обоих.
                    degradations.append(
                        wantsTranslation
                            ? "без перевода и AI-чистки: \(error.localizedDescription)"
                            : "без AI-чистки: \(error.localizedDescription)"
                    )
                    logger.error("GPT-слой не отработал: \(error.localizedDescription, privacy: .public)")
                }
            } else if wantsTranslation {
                degradations.append("без перевода")
            }

            // Пустой ответ модели `cleanup` отсекает сам, но вставлять пустоту нельзя ни при
            // каких обстоятельствах: откатываемся на результат слоя 2 и говорим об этом.
            if translation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                translation = nil
                degradations.append("без перевода: пустой ответ модели")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DictationError.noSpeech
            }
            lastOriginal = text
            lastOriginalLanguage = language
            lastTranslation = translation

            // Непустой по построению: перевод либо непустой, либо сброшен в nil выше.
            let output = translation ?? text
            let outcome = await insert(output)
            history.add(output, language: language)
            await finishBackup(backup)

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

    /// Финал по потоковому пути: подтверждённая фоном часть уже распознана, осталось
    /// декодировать хвост от `confirmedEndSample` (с нахлёстом назад) и склеить.
    ///
    /// `nil` — путь неприменим или не дал результата; вызывающий код идёт обычным полным
    /// проходом. Это железное правило: ускорение не имеет права стать риском для текста.
    private func streamedTranscript(samples: [Float], language: Language) async -> String? {
        guard !rollingFailed,                              // фоновый проход падал
              !languageSwitchedDuringSession,              // язык переключали на записи
              samples.count >= Self.streamingMinSamples,   // диктовка короче 6 с
              confirmedEndSample > 0,                      // подтверждать нечего
              !confirmedText.isEmpty,
              confirmedEndSample < samples.count
        else { return nil }

        do {
            let start = max(0, confirmedEndSample - Self.tailOverlap)
            // Буфер целиком не обрезаем: подтверждённые сегменты уже без ведущей тишины —
            // её отрезали таймкоды Whisper. Тем же гейтом снимаем тишину по краям хвоста.
            let vad = try await ensureVad()
            guard let tail = try await vad.trimmed(Array(samples[start...])) else { return nil }

            let tailText = try await gate.transcribe(tail, language: language, prompt: sessionPrompt)
            // Пустой хвост — не «там была тишина», а признак того, что проход не удался
            // (например, окно короче внутреннего `windowClipTime` WhisperKit). Слова терять
            // нельзя, поэтому откатываемся на полный проход.
            guard !tailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return StreamingMerge.merge(confirmed: confirmedText, tail: tailText)
        } catch {
            logger.error("Потоковая финализация не удалась: \(error.localizedDescription, privacy: .public)")
            return nil
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
        // Без GPT переводить нечем: не ждём таймаут впустую (пункт меню гейтит и UI).
        guard settings.gptEnabled else {
            flash("перевод не удался: GPT выключен")
            return
        }
        do {
            let translated = try await PostProcessor.cleanup(
                text: original,
                entries: dictionary.entries,
                // Именно язык `lastOriginal`: с прошлой диктовки язык могли переключить.
                language: lastOriginalLanguage,
                config: settings.gptConfig,
                translateToEnglish: true
            )
            // Пока переводили, могла закончиться новая диктовка — её кэш чужим переводом
            // не портим, но пользователю отдаём то, что он запросил.
            if lastOriginal == original {
                lastTranslation = translated
            }
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

    /// `TextInserter.insert` синхронно спит 20 мс — уводим с главного потока.
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

    /// Сбой показываем как есть: черновика больше нет (live-превью убрано вместе с панелью
    /// текста), а сама запись лежит в бэкапе `last-recording.wav`.
    private func fail(_ message: String) {
        state = .error(message)
        scheduleIdle(after: Self.errorLinger)
    }

    /// Сессию отменили хоткеем на загрузке модели (Whisper или VAD): записи не было,
    /// поэтому тихо возвращаемся в простой — без сообщения об ошибке.
    private func cancelSession() {
        pendingCancel = false
        state = .idle
        activeSessionLanguage = nil
        // Микрофон к этому моменту мог быть уже прогрет (отмена на подъёме VAD идёт после
        // `recorder.prepare()`), а `begin()` снял таймер отпускания — возвращаем его,
        // иначе индикатор записи останется гореть.
        scheduleMicRelease()
    }

    private func scheduleIdle(after seconds: TimeInterval) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.state = .idle
            self.activeSessionLanguage = nil
            self.scheduleMicRelease()
        }
    }

    /// Микрофон отпускаем почти сразу после возврата в простой: индикатор записи не должен
    /// гореть после вставки. Задержка в 0.5 c только склеивает диктовки, идущие подряд.
    private func scheduleMicRelease() {
        micReleaseTask?.cancel()
        micReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.micReleaseDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.recorder.teardown()
        }
    }

    /// Кодирование и запись WAV — вне главного потока и вне критического пути. `samples`
    /// уезжает в задачу значением (массив уже никто не меняет), поэтому снимок консистентен.
    private func startBackup(_ samples: [Float]) -> Task<String?, Never> {
        let url = Self.backupURL
        return Task.detached(priority: .utility) { () -> String? in
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
        }
    }

    /// Вставка дошла до приложения — бэкап больше не нужен. Ждём саму запись: без этого
    /// припозднившийся `write` положил бы WAV обратно уже после удаления, и в следующей
    /// сессии на диске лежал бы чужой файл.
    private func finishBackup(_ backup: Task<String?, Never>) async {
        if let failure = await backup.value {
            logger.error("Бэкап записи не сохранён: \(failure, privacy: .public)")
        }
        try? FileManager.default.removeItem(at: Self.backupURL)
    }
}
