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
    /// Поля ввода не нашлось: текст лежит в буфере обмена и висит карточкой у нижнего
    /// левого угла экрана. Это удача, а не сбой, — отсюда и своё состояние, а не `.degraded`.
    case carded
    /// Диктовку отменили (Esc): результата нет и не будет. Это не сбой, а осознанный отказ,
    /// поэтому и состояние своё — предупреждающего значка отмене не положено.
    case cancelled
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
    /// Потолок стыка. В нахлёст 0.5 c физически помещается 1–3 слова, поэтому длиннее искать
    /// нечего — а вредно: на повторах («да да да да») длинный «стык» съел бы настоящий повтор.
    /// Четыре слова — это верхняя граница возможной потери, а не рабочая длина.
    private static let maxOverlapWords = 4

    /// Что из прохода можно считать устоявшимся: все сегменты, кроме последнего — его Whisper
    /// почти всегда переписывает на следующем проходе, когда слышит конец фразы.
    /// `nil` — подтверждать нечего.
    static func confirmed(from segments: [ASRSegment]) -> (text: String, endSample: Int)? {
        // Хвостовые пустые сегменты текста не дают, но подняли бы границу подтверждённого —
        // и следующий, уже осмысленный проход не смог бы её сдвинуть (граница монотонна).
        var stable = segments.dropLast()
        while let last = stable.last, last.text.isEmpty {
            stable = stable.dropLast()
        }
        // Таймкод считаем индексом, а `Int(_:)` падает на NaN и бесконечности — проверяем
        // диапазоном: он же отсекает отрицательные и заведомо абсурдные значения.
        guard let last = stable.last, (0..<Double(24 * 3600)).contains(last.end) else { return nil }

        let text = stable.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return (text, Int(last.end * AudioCaptureFormat.sampleRate))
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
    public static func encode(_ samples: [Float], sampleRate: Int = Int(AudioCaptureFormat.sampleRate)) -> Data {
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
    private static let rollingGrowth = AudioCaptureFormat.samples(seconds: 2)
    /// Нахлёст хвоста назад: даёт склейке общие слова на стыке.
    private static let tailOverlap = AudioCaptureFormat.samples(seconds: 0.5)
    /// Короче этого потоковый путь не включаем: полный проход и так быстрый,
    /// а лишний риск на коротких диктовках не окупается.
    private static let streamingMinSamples = AudioCaptureFormat.samples(seconds: 6)
    /// Дальше этого новые проходы не стартуют. Каждый проход переписывает весь буфер, а буфер
    /// только растёт — на длинной записи это квадратичное сжигание ANE, и вдобавок стоп ждал бы
    /// многосекундный проход. Подтверждённое к этому моменту остаётся в силе.
    private static let rollingMaxSamples = AudioCaptureFormat.samples(seconds: 50)

    /// Меньше этого записанного при сорвавшемся захвате — распознавать нечего.
    private static let minimumUsefulSamples = AudioCaptureFormat.samples(seconds: 0.5)

    /// Сколько держим финальное состояние перед возвратом в `.idle`.
    private static let insertedLinger: TimeInterval = 1.5
    private static let degradedLinger: TimeInterval = 2.5
    private static let errorLinger: TimeInterval = 2
    /// Вспышка «отменено» короче остальных: сообщать не о чем, надо лишь показать,
    /// что Esc дошёл и диктовки больше нет.
    private static let cancelledLinger: TimeInterval = 1.2
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
    /// Перевод, назначенный этой сессии хоткеем (правый ⌥), — он сильнее настройки.
    /// `nil` — сессии с переопределением нет, решает `settings.translateToEnglish`
    /// (в том числе прямо на стопе: обычную сессию тумблер меню меняет и на живой записи).
    @Published public private(set) var activeSessionTranslate: Bool?

    /// Текст, которому не нашлось поля ввода, — его забирает стопка карточек в приложении.
    /// Замыкание, а не `@Published`: ядро остаётся без UI, а карточка должна появиться
    /// ровно один раз на диктовку, а не на каждую пересборку подписчика.
    /// Возвращает `false`, если карточку показать не удалось, — тогда конвейер вставляет
    /// текст обычным путём. Не назначен — конвейер вставляет по-старому (так живёт CLI).
    public var onCardText: ((String) -> Bool)?

    private let gate: EngineGate
    private let dictionary: UserDictionary
    private let settings: AppSettings
    private let history: HistoryStore
    private let recorder: AudioCapturing
    private let delivery: TextDelivery
    private let makeVad: @Sendable () async throws -> SpeechGating
    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "Dictation")

    private var vad: SpeechGating?
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
    /// Отмену на загрузке запросил Esc, а не второй хоткей: он обязан мигнуть «Отменено».
    /// Второй хоткей гасит сессию молча — он же её и завёл, спрашивать там нечего.
    private var pendingCancelFlashes = false
    /// Esc нажали, пока конвейер уже считал. Прервать идущий проход (или запрос к GPT)
    /// нечем — он досчитает в никуда, а конвейер посмотрит флаг перед вставкой.
    private var cancelRequested = false

    /// Подтверждённая часть диктовки: все сегменты последнего фонового прохода, кроме
    /// последнего (его следующий проход почти всегда переписывает), и конец последнего
    /// подтверждённого сегмента в сэмплах от начала записи.
    ///
    /// Не private: тест отмены проверяет напрямую, что проход отменённой сессии сюда
    /// не доезжает (как и подмена сообщения в `message(for:)`).
    var confirmedText = ""
    var confirmedEndSample = 0
    /// Фоновый проход упал — на этой сессии потоковый путь выключен.
    private var rollingFailed = false
    /// Язык переключили прямо на записи — фоновые проходы и хвост могли бы разъехаться.
    private var languageSwitchedDuringSession = false
    /// Длина буфера на момент запуска последнего фонового прохода.
    private var rollingPassSamples = 0
    /// Номер сессии: проход, посчитанный до старта новой записи, к ней не относится —
    /// тот же приём, что `generation` в `VadGate`.
    private var sessionGeneration = 0
    /// Промпт сессии: фоновые проходы и финал обязаны идти с одним биасингом, иначе
    /// подтверждённая часть и хвост распознаны по-разному и склейка врёт.
    private var sessionPrompt = ""

    private var chunks: AsyncStream<[Float]>.Continuation?
    private var vadTask: Task<Void, Never>?
    private var rollingTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var micReleaseTask: Task<Void, Never>?
    private var deviceSubscription: AnyCancellable?

    public init(
        engine: TranscriptionEngine,
        dictionary: UserDictionary,
        settings: AppSettings,
        recorder: AudioCapturing = CaptureRecorder(),
        // Последний шаг конвейера — единственное место, где ядро трогает чужие окна и общий
        // буфер обмена. Тесты подставляют сюда свою доставку и обходятся без того и другого.
        delivery: TextDelivery = .system,
        // Не сам гейт, а фабрика: подъём VAD (CoreML/ANE) занимает секунды и делается лениво,
        // при первой записи. Тесты подставляют сюда заглушку и обходятся без модели.
        makeVad: @escaping @Sendable () async throws -> SpeechGating = { try await VadGate() }
    ) {
        self.gate = EngineGate(engine)
        self.dictionary = dictionary
        self.settings = settings
        self.history = .shared
        self.recorder = recorder
        self.delivery = delivery
        self.makeVad = makeVad

        recorder.setInputDevice(uid: settings.inputDeviceUID)
        // Текущее значение уже применено выше — подписка нужна только на последующие смены.
        deviceSubscription = settings.$inputDeviceUID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // На живой записи устройство не меняем: середина диктовки — не место
                    // для дырки в звуке. Новый микрофон применит `begin()` следующей.
                    if case .recording = self.state { return }
                    self.recorder.setInputDevice(uid: uid)
                }
            }
    }

    // MARK: - Вход хоткеев

    /// `translating` назначает переводом всю сессию поверх настройки; `nil` — как раньше,
    /// решает `settings.translateToEnglish`. На остановке (и на отмене загрузки) параметр
    /// не смотрим вовсе: остановить и отменить сессию вправе любой хоткей, а решение
    /// о переводе принято при её старте.
    public func toggle(translating: Bool? = nil) {
        switch state {
        case .recording:
            stopAndProcess()
        case .idle, .inserted, .carded, .cancelled, .degraded, .error:
            begin(translating: translating)
        case .preparingModel:
            // Первая загрузка модели идёт минутами — хоткей отменяет сессию, а не ждёт впустую.
            pendingCancel = true
        case .transcribing, .cleaning:
            break  // конвейер занят — хоткей игнорируем
        }
    }

    /// Esc снимает идущую диктовку на любом её шаге: записанное выбрасывается целиком —
    /// ни распознавания, ни вставки, ни истории, ни «последней диктовки».
    ///
    /// Чайм остановки здесь намеренно не играем: он означает «записал, обрабатываю»,
    /// а отмена — это «ничего не было». Тишина честнее звука.
    public func cancelDictation() {
        switch state {
        case .recording:
            discardRecording()
        case .preparingModel:
            // Тот же путь, что у второго хоткея: саму загрузку прервать нечем, но записи
            // после неё не будет. Разница одна — Esc мигает отменой на любом шаге, иначе
            // непонятно, дошло нажатие или нет.
            pendingCancel = true
            pendingCancelFlashes = true
        case .transcribing, .cleaning:
            cancelRequested = true
        case .idle, .inserted, .carded, .cancelled, .degraded, .error:
            break  // сессии нет — отменять нечего
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

    private func begin(translating: Bool?) {
        guard !isStarting else { return }  // старт уже идёт — второй хоткей игнорируем
        isStarting = true
        // Отмена прошлой сессии новую не трогает — все её флаги снимаем на старте.
        pendingCancel = false
        pendingCancelFlashes = false
        cancelRequested = false

        idleTask?.cancel()
        idleTask = nil
        micReleaseTask?.cancel()
        micReleaseTask = nil
        prewarmGPT()

        let language = settings.language
        sessionLanguage = language
        activeSessionLanguage = language
        activeSessionTranslate = translating
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
                // Выбор устройства дёшев: это запись UID, само устройство резолвится на старте
                // сессии. Микрофон здесь ещё не поднимаем — это делает `startCapture()` прямо
                // перед записью, иначе индикатор загорится на секунды раньше первого звука.
                recorder.setInputDevice(uid: settings.inputDeviceUID)
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
        sessionGeneration += 1
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
        recorder.onFailure = { [weak self] reason in
            Task { @MainActor in self?.captureFailed(reason) }
        }

        // Микрофон поднимаем ровно здесь: подъём VAD (CoreML/ANE) выше занимает секунды,
        // и всё это время индикатор записи гореть не должен. Сам подъём асинхронный —
        // главный поток на нём не ждёт.
        recorder.prepare()

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
            recorder.onFailure = nil
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
        let generation = sessionGeneration
        rollingTask = Task { [weak self] in
            while true {
                // Потоковый путь уже снят (упавший проход, переключённый язык) — жечь на него
                // ANE до конца записи незачем.
                guard let self, case .recording = self.state,
                      generation == self.sessionGeneration,
                      !self.rollingFailed, !self.languageSwitchedDuringSession
                else { return }

                // Опрашиваем длину, а не сам буфер: снимок массива стоит копии по записи
                // на аудиопотоке. Дальше потолка новые проходы не стартуют вовсе.
                let captured = self.recorder.capturedSampleCount
                guard captured <= Self.rollingMaxSamples else { return }
                // До порога потокового пути проходы бессмысленны и вредны: короткая диктовка
                // всё равно пойдёт полным проходом, а идущий проход стоп обязан дождаться —
                // это была бы чистая потеря там, где скорость важнее всего.
                guard captured >= Self.streamingMinSamples,
                      captured - self.rollingPassSamples >= Self.rollingGrowth
                else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.rollingPoll * 1_000_000_000))
                    continue
                }

                let samples = self.recorder.capturedSamples
                self.rollingPassSamples = samples.count

                do {
                    let segments = try await self.gate.transcribeSegments(
                        samples,
                        language: language,
                        prompt: prompt
                    )
                    self.confirm(segments, generation: generation)
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

    private func confirm(_ segments: [ASRSegment], generation: Int) {
        // Пока проход считался, могла начаться новая запись — её подтверждать чужим текстом
        // нельзя. Назад тоже не сдаём: перестройка сегментов может дать более короткий
        // подтверждённый префикс, и тогда честнее оставить прошлый — хвост всё равно длиннее.
        guard generation == sessionGeneration,
              let pass = StreamingMerge.confirmed(from: segments),
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
    private func startVadLoop(stream: AsyncStream<[Float]>, vad: SpeechGating) {
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

    /// Захват сорвался на живой записи: микрофон не отдал ни одного блока, устройство
    /// исчезло, сессию прервали. Записанное до сбоя не выбрасываем — если там есть что
    /// распознавать, идём обычным стопом; если нет, честно говорим о микрофоне вместо
    /// бессмысленного «речь не обнаружена».
    private func captureFailed(_ reason: String) {
        guard case .recording = state else { return }
        // Обрывок короче полусекунды распознавать нечего — на нём конвейер выдал бы
        // «речь не обнаружена» вместо настоящей причины (микрофон отвалился).
        if recorder.capturedSampleCount >= Self.minimumUsefulSamples {
            logger.error("Захват сорвался (\(reason, privacy: .public)) — обрабатываю записанное")
            stopAndProcess()
            return
        }
        chunks?.finish()
        chunks = nil
        vadTask?.cancel()
        vadTask = nil
        rollingTask?.cancel()
        rollingTask = nil
        recorder.onLevel = nil
        recorder.onFailure = nil
        _ = recorder.stop()
        scheduleMicRelease()
        fail(reason)
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
        recorder.onFailure = nil

        let samples = recorder.stop()
        // Микрофон дальше не нужен: распознавание и GPT-чистка занимают секунды, и всё это
        // время индикатор записи гореть не должен. Диктовки подряд ничего не теряют —
        // `begin()` снимает этот таймер первым делом.
        scheduleMicRelease()
        if settings.soundsEnabled { SoundPlayer.shared.playStop() }
        let language = sessionLanguage
        state = .transcribing
        Task { await runPipeline(samples: samples, language: language) }
    }

    /// Отмена на живой записи: захват сворачиваем так же, как на обычном стопе, но буфер
    /// выбрасываем — он никуда не уезжает, поэтому и бэкап-WAV писать незачем.
    private func discardRecording() {
        chunks?.finish()
        chunks = nil
        vadTask?.cancel()
        vadTask = nil
        // Идущий фоновый проход не прерывается: `EngineGate` отмену не смотрит, а WhisperKit
        // не умеет её вовсе — он досчитает в никуда, как и загрузка модели на отмене.
        // Сдвинутое поколение делает его результат заведомо мёртвым: `confirm` отбросит
        // сегменты, даже если они придут раньше, чем начнётся следующая запись.
        rollingTask?.cancel()
        rollingTask = nil
        sessionGeneration += 1
        recorder.onLevel = nil
        recorder.onFailure = nil
        _ = recorder.stop()
        // Микрофон отпускаем по обычному расписанию: отмена — не повод держать индикатор
        // записи, но и не повод рвать прогрев для следующей диктовки.
        scheduleMicRelease()
        cancelled()
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
            // Esc уже нажали — круг к GPT отменённой диктовке не нужен: это секунды ожидания
            // и оплаченные токены ради текста, который никто не увидит.
            if consumeCancel() { return }
            var degradations: [String] = []
            // Хоткей сессии сильнее настройки; без него всё как раньше — решает тумблер.
            let wantsTranslation = activeSessionTranslate ?? settings.translateToEnglish
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
                    // Поэтому и модель берём переводческую — вызов целиком принадлежит переводу.
                    let processed = try await PostProcessor.cleanup(
                        text: text,
                        entries: entries,
                        language: language,
                        config: wantsTranslation ? settings.translateGPTConfig : settings.gptConfig,
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
            // Последняя точка отмены: дальше идут вставка, буфер обмена и история — ровно то,
            // чего отменённая диктовка оставить не должна. Бэкап-WAV при этом остаётся лежать
            // на диске: он безвреден и его перезапишет следующая запись.
            if consumeCancel() { return }
            lastOriginal = text
            lastOriginalLanguage = language
            lastTranslation = translation

            // Непустой по построению: перевод либо непустой, либо сброшен в nil выше.
            let output = translation ?? text
            let destination = await deliver(output)
            history.add(output, language: language)
            await finishBackup(backup)

            if case .pasteboard(.clipboardOnly(let reason)) = destination {
                degradations.append(Self.clipboardMessage(reason))
            }
            // Оговорка про AI-чистку не должна съедать главную новость: текст не в документе,
            // а в карточке — без этого пользователь пойдёт искать его не там.
            if case .card = destination, !degradations.isEmpty {
                degradations.append("текст в карточке")
            }
            if !degradations.isEmpty {
                state = .degraded(degradations.joined(separator: "; "))
                scheduleIdle(after: Self.degradedLinger)
            } else {
                switch destination {
                case .card: state = .carded
                case .pasteboard: state = .inserted
                }
                scheduleIdle(after: Self.insertedLinger)
            }
        } catch {
            // Отменённая диктовка не ругается: пользователь уже сказал, что результат ему
            // не нужен, и сбой досчитанного впустую конвейера — не его новость.
            if consumeCancel() { return }
            fail(message(for: error))
        }
    }

    /// «Речь не обнаружена» на цифровой тишине — неправда: молчал не человек, а микрофон
    /// (так ведёт себя мёртвый HFP-вход Bluetooth-гарнитуры). Говорим то, что помогает.
    /// Не private: подмена сообщения проверяется тестом напрямую.
    func message(for error: Error) -> String {
        guard error is DictationError, recorder.capturedSilence else { return error.localizedDescription }
        return "микрофон молчит — выберите другой вход в меню «Микрофон»"
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
                config: settings.translateGPTConfig,
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
        delivery.copy(text)
    }

    /// Короткое сообщение поверх простоя: работающий конвейер не перебиваем.
    private func flash(_ message: String) {
        switch state {
        case .idle, .inserted, .carded, .cancelled, .degraded, .error:
            state = .degraded(message)
            scheduleIdle(after: Self.flashLinger)
        case .preparingModel, .recording, .transcribing, .cleaning:
            break
        }
    }

    /// Куда уехал готовый текст.
    private enum Destination {
        case pasteboard(InsertOutcome)
        case card
    }

    /// Последний шаг: либо обычная вставка, либо — если вставлять некуда — карточка.
    ///
    /// Карточка появляется только при четырёх «да» разом: настройка включена, стопка карточек
    /// вообще есть (в CLI её нет), детектор уверенно говорит, что поля ввода нет, и сама
    /// стопка карточку приняла. Любое сомнение (`.unknown`) — это прежний Cmd-V: терять
    /// текст в карточке там, где его ждали в документе, нельзя.
    private func deliver(_ text: String) async -> Destination {
        guard settings.cardsWhenNoField, let onCardText else { return .pasteboard(await insert(text)) }

        let verdict = await focusVerdict()
        guard verdict.state == .notEditable else {
            logRouting(verdict, path: "вставка")
            return .pasteboard(await insert(text))
        }

        // Контракт буфера обмена прежний: текст остаётся в пастборде в любом случае —
        // карточку можно и не трогать, а просто нажать Cmd-V самому.
        delivery.copy(text)
        // Стопка может отказать (не нашла экрана) — тогда текст обязан уехать обычным путём,
        // иначе он молча пропадёт: состояние скажет «в карточку», а карточки не будет.
        guard onCardText(text) else {
            logRouting(verdict, path: "вставка (стопка отказала)")
            return .pasteboard(await insert(text))
        }
        logRouting(verdict, path: "карточка")
        return .card
    }

    /// Единственная строка, по которой полевой отчёт «карточка не появилась» вообще можно
    /// разобрать: что ответил AX, какая была роль, кто был впереди и куда уехал текст.
    ///
    /// Уровень строго `.notice` (это `OS_LOG_TYPE_DEFAULT`): он один ложится на диск и виден
    /// в обычном `log show`. `.info` живёт в кольцевом буфере памяти, и прошлый полевой
    /// отчёт «в логе пусто» получился ровно из-за этого (плюс `log` в zsh — встроенная
    /// команда, так что `log show …` из-под zsh отвечает «too many arguments», а не строками;
    /// звать надо `/usr/bin/log`).
    private func logRouting(_ verdict: FocusVerdict, path: String) {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "—"
        logger.notice(
            """
            Доставка: фокус=\(String(describing: verdict.state), privacy: .public) \
            роль=\(verdict.role ?? "—", privacy: .public) \
            впереди=\(app, privacy: .public) → \(path, privacy: .public)
            """
        )
    }

    /// `TextInserter.insert` синхронно спит 20 мс — уводим с главного потока.
    private func insert(_ text: String) async -> InsertOutcome {
        let delivery = self.delivery
        return await Task.detached(priority: .userInitiated) { delivery.insert(text) }.value
    }

    /// Опрос AX ходит в чужой процесс и блокирует поток — главный на это не занимаем.
    private func focusVerdict() async -> FocusVerdict {
        let delivery = self.delivery
        return await Task.detached(priority: .userInitiated) { delivery.focus() }.value
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

    private func ensureVad() async throws -> SpeechGating {
        if let vad { return vad }
        state = .preparingModel(1)
        let created = try await makeVad()
        vad = created
        return created
    }

    /// Сбой показываем как есть: черновика больше нет (live-превью убрано вместе с панелью
    /// текста), а сама запись лежит в бэкапе `last-recording.wav`.
    private func fail(_ message: String) {
        state = .error(message)
        scheduleIdle(after: Self.errorLinger)
    }

    /// Вспышка «отменено» и возврат в простой. Отдельно от `fail`: отмена — не сбой.
    private func cancelled() {
        cancelRequested = false
        state = .cancelled
        scheduleIdle(after: Self.cancelledLinger)
    }

    /// `true` — Esc нажали, пока конвейер считал: показываем вспышку, дальше не идём.
    private func consumeCancel() -> Bool {
        guard cancelRequested else { return false }
        cancelled()
        return true
    }

    /// Сессию отменили хоткеем на загрузке модели (Whisper или VAD): записи не было,
    /// поэтому тихо возвращаемся в простой — без сообщения об ошибке.
    private func cancelSession() {
        let flashes = pendingCancelFlashes
        pendingCancel = false
        pendingCancelFlashes = false
        // Отмену по Esc показываем так же, как на записи и на конвейере: `cancelled()` сам
        // вернёт в простой и отпустит микрофон через `scheduleIdle`.
        guard !flashes else {
            cancelled()
            return
        }
        state = .idle
        activeSessionLanguage = nil
        activeSessionTranslate = nil
        // Эта сессия микрофон поднять не успела, но прошлая могла оставить его прогретым,
        // а `begin()` снял таймер отпускания — возвращаем его, иначе индикатор записи
        // останется гореть.
        scheduleMicRelease()
    }

    private func scheduleIdle(after seconds: TimeInterval) {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.state = .idle
            self.activeSessionLanguage = nil
            self.activeSessionTranslate = nil
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
    /// О сбое задача сообщает сама: её результата может никто не прочитать — при сбое
    /// конвейера до `finishBackup` дело не доходит вовсе.
    private func startBackup(_ samples: [Float]) -> Task<Void, Never> {
        let url = Self.backupURL
        let logger = self.logger
        return Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try WavEncoder.encode(samples).write(to: url, options: .atomic)
            } catch {
                let message = "Бэкап записи не сохранён: \(error.localizedDescription)"
                logger.error("\(message, privacy: .public)")
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
        }
    }

    /// Вставка дошла до приложения — бэкап больше не нужен. Ждём саму запись: без этого
    /// припозднившийся `write` положил бы WAV обратно уже после удаления, и в следующей
    /// сессии на диске лежал бы чужой файл.
    private func finishBackup(_ backup: Task<Void, Never>) async {
        await backup.value
        try? FileManager.default.removeItem(at: Self.backupURL)
    }
}
