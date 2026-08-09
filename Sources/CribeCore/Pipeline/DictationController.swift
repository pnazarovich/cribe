import AppKit
import Combine
import Foundation
import OSLog

/// Единственный канал прогресса и ошибок конвейера: UI подписан на `DictationController.state`.
/// Две очень разные стадии подготовки модели, и путать их нельзя: у скачивания прогресс
/// настоящий, у прогрева его нет вовсе. CoreML не сообщает, сколько осталось до конца
/// компиляции под нейродвижок, а она идёт минуты — поэтому вместо выдуманных процентов
/// показываем прошедшее время: видно, что работа идёт, и никто не обманут.
public enum ModelPreparation: Sendable, Equatable {
    /// Доля скачанного, 0...1.
    case downloading(Double)
    /// Прогрев и компиляция под нейродвижок. Момент входа — чтобы считать от него секунды.
    case warming(since: Date)
}

public enum DictationState: Sendable, Equatable {
    case idle
    case preparingModel(ModelPreparation)
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

/// Короткая записка рядом с панелью. Пилюля одна, а дел теперь бывает два сразу (пишется
/// одна диктовка, доезжает другая), поэтому у сообщений, которым пилюли не досталось,
/// должен быть свой выход — иначе они просто пропадут.
///
/// Ядро остаётся без UI: оно называет ПОВОД, а текст и внешний вид выбирает приложение.
public enum DictationNotice: Sendable, Equatable {
    /// Очередь заполнена — новую диктовку начинать некуда, пока не доедет одна из идущих.
    case queueFull(limit: Int)
    /// Разовая подсказка: можно не ждать обработки, а сразу говорить дальше.
    case parallelHint
    /// Итог диктовки, которому не хватило пилюли: её занимает более срочное.
    case result(DictationState)
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

    /// То же, но вариант модели назван явно, — повторный разбор записи из истории.
    func prepare(
        variant: String,
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws {
        try await engine.prepare(variant: variant, language: language, onState: onState)
    }

    /// Проход с переводом: модель сразу отдаёт английский. Ходит той же цепочкой, что и
    /// обычный, — инстанс WhisperKit один на всех.
    func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String {
        let previous = inFlight
        let task = Task { [self] in
            _ = await previous?.value
            return try await engine.transcribe(
                samples, language: language, prompt: prompt, translating: translating
            )
        }
        inFlight = Task { _ = try? await task.value }
        return try await task.value
    }

    func transcribe(_ samples: [Float], language: Language, variant: String, prompt: String) async throws -> String {
        let previous = inFlight
        let task = Task { [self] in
            await previous?.value
            return try await engine.transcribe(samples, language: language, variant: variant, prompt: prompt)
        }
        chain(task)
        return try await task.value
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

    /// Тот же проход, но с уверенностью по словам.
    func transcribeDetailed(_ samples: [Float], language: Language, prompt: String) async throws -> Transcript {
        let previous = inFlight
        let task = Task { [self] in
            await previous?.value
            return try await engine.transcribeDetailed(samples, language: language, prompt: prompt)
        }
        chain(task)
        return try await task.value
    }

    /// Второе мнение о соседнем языке: тот же порядок, что и у проходов, — оно тоже
    /// занимает модель, и лезть в неё поперёк идущего распознавания нельзя.
    func reconsideringNeighbour(
        _ text: String,
        samples: [Float],
        language: Language,
        prompt: String
    ) async -> NeighbourPass {
        let previous = inFlight
        let task = Task { [self] in
            await previous?.value
            return await engine.reconsideringNeighbour(
                text, samples: samples, language: language, prompt: prompt
            )
        }
        inFlight = Task { _ = try? await task.value }
        return (try? await task.value) ?? NeighbourPass(text: text)
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
    static func confirmed(from segments: [ASRSegment]) -> (text: String, endSample: Int, words: [WordProbe])? {
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
        // Уверенность берём с той же устоявшейся части, что и текст: последний сегмент
        // Whisper почти всегда переписывает, и его слова — самые неуверенные в проходе.
        // Взять их значило бы кричать на каждой длинной диктовке.
        return (text, Int(last.end * AudioCaptureFormat.sampleRate), stable.flatMap(\.words))
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

/// Одна диктовка от первого шага до последнего: сначала она пишется с микрофона, потом
/// стоит в очереди и доезжает до поля ввода.
///
/// Ссылочный тип не ради удобства. Фоновый проход, начатый во время записи, досчитывает
/// уже ПОСЛЕ стопа, и подтверждать ему надо ту самую диктовку, из которой он вырос, —
/// а она к этому моменту уже не «текущая»: с микрофона пишется следующая.
@MainActor
private final class DictationSession {

    // MARK: Снято на старте — дальше не меняется

    let language: Language
    /// Перевод, назначенный хоткеем (правый ⌥); nil — решает настройка.
    let translating: Bool?
    /// Промпт диктовки: фоновые проходы и финал обязаны идти с одним биасингом, иначе
    /// подтверждённая часть и хвост распознаны по-разному и склейка врёт.
    var prompt = ""

    // MARK: Живёт, пока идёт запись

    /// Подтверждённая фоном часть и конец последнего подтверждённого сегмента в сэмплах
    /// от начала записи.
    var confirmedText = ""
    var confirmedEndSample = 0
    /// Уверенность по словам подтверждённой части и хвоста — из тех же проходов, что и текст.
    var confirmedWords: [WordProbe] = []
    var tailWords: [WordProbe] = []
    /// Фоновый проход упал — на этой диктовке потоковый путь выключен.
    var rollingFailed = false
    /// Язык переключили прямо на записи — фоновые проходы и хвост могли бы разъехаться.
    var languageSwitched = false
    /// Длина буфера на момент запуска последнего фонового прохода.
    var rollingPassSamples = 0
    var rollingTask: Task<Void, Never>?
    /// Диктовку сняли ещё на записи (Esc, сбой захвата): досчитавшему проходу подтверждать
    /// уже нечего.
    var cancelled = false

    // MARK: Снято на стопе — с этим диктовка едет в очередь

    var samples: [Float] = []
    /// Тумблер перевода читаем на стопе: меню меняет его и на живой записи, а после стопа
    /// решение принято — в очереди диктовку настройка догонять уже не вправе.
    var translatesToEnglish = false
    /// Записанное оказалось цифровой тишиной. Снимок, а не опрос захвата: пока диктовка
    /// стоит в очереди, микрофон успевает записать следующую и ответил бы уже про неё.
    var capturedSilence = false

    init(language: Language, translating: Bool?) {
        self.language = language
        self.translating = translating
    }

    /// Итог фонового прохода. Назад не сдаём: перестройка сегментов может дать более
    /// короткий подтверждённый префикс, и тогда честнее оставить прошлый — хвост всё
    /// равно длиннее.
    func confirm(_ segments: [ASRSegment]) {
        guard !cancelled,
              let pass = StreamingMerge.confirmed(from: segments),
              pass.endSample > confirmedEndSample
        else { return }
        confirmedEndSample = pass.endSample
        confirmedText = pass.text
        confirmedWords = pass.words
    }
}

/// Конвейер диктовки: запись → VAD → Whisper → словарь → GPT → вставка.
///
/// Диктовок в работе бывает несколько сразу: пока одна распознаётся и чистится, следующая
/// уже пишется с микрофона. Поэтому контроллер разделён надвое честно, а не флагами поверх
/// одной машины состояний:
///
/// * `recording` — единственная диктовка, которая пишется прямо сейчас. Ей принадлежат
///   микрофон, ворота речи, фоновые проходы и Esc.
/// * `pending` — очередь уже записанных диктовок, которые доезжают до поля ввода. Ей
///   принадлежит инстанс WhisperKit и всё, что идёт после стопа.
///
/// Очередь разбирается строго по одной и строго в порядке речи: инстанс WhisperKit один
/// (параллельные проходы только мешали бы друг другу), а переставленные местами
/// предложения хуже, чем медленные.
@MainActor
public final class DictationController: ObservableObject {

    /// Потоковая финализация. Фоновый проход стартует не раньше, чем через `rollingGap`
    /// после конца предыдущего, и только если с прошлого прохода записалось ещё
    /// `rollingGrowth` звука — иначе проходы шли бы сплошняком без нового материала.
    /// Не private: длинную диктовку меряет проба `LongAudioProbeTests`, и расписание
    /// проходов в ней обязано быть тем же самым, а не переписанным по памяти.
    static let rollingGap: TimeInterval = 0.5
    private static let rollingPoll: TimeInterval = 0.1
    static let rollingGrowth = AudioCaptureFormat.samples(seconds: 2)
    /// Нахлёст хвоста назад: даёт склейке общие слова на стыке.
    static let tailOverlap = AudioCaptureFormat.samples(seconds: 0.5)
    /// Короче этого потоковый путь не включаем: полный проход и так быстрый,
    /// а лишний риск на коротких диктовках не окупается.
    static let streamingMinSamples = AudioCaptureFormat.samples(seconds: 6)
    /// Дальше этого новые проходы не стартуют. Каждый проход переписывает весь буфер, а буфер
    /// только растёт — на длинной записи это квадратичное сжигание ANE, и вдобавок стоп ждал бы
    /// многосекундный проход. Подтверждённое к этому моменту остаётся в силе.
    static let rollingMaxSamples = AudioCaptureFormat.samples(seconds: 50)

    /// Сколько записанных диктовок вправе ждать обработки. Потолок нужен не ради памяти,
    /// а ради контроля: за четвёртой человек уже не помнит, что сказал в первой, и очередь
    /// из «сейчас допечатается» превращается в «где мой текст».
    public static let maxPending = 3

    /// На какой по счёту диктовке показываем разовую подсказку про наложение. Третья —
    /// момент, когда привычка нажимать хоткей уже есть, а про то, что ждать не нужно,
    /// человек ещё не знает.
    private static let parallelHintAt = 3

    /// Меньше этого записанного при сорвавшемся захвате — распознавать нечего.
    private static let minimumUsefulSamples = AudioCaptureFormat.samples(seconds: 0.5)

    /// Сколько держим финальное состояние перед возвратом в `.idle`.
    private static let insertedLinger: TimeInterval = 1.5
    private static let degradedLinger: TimeInterval = 2.5
    private static let errorLinger: TimeInterval = 2
    /// Вспышка «отменено» короче остальных: сообщать не о чем, надо лишь показать,
    /// что Esc дошёл и записи больше нет.
    private static let cancelledLinger: TimeInterval = 1.2
    /// Сообщение действий меню (перевод последней диктовки) поверх простоя.
    private static let flashLinger: TimeInterval = 2
    /// Через столько простоя отпускаем микрофон (гаснет индикатор записи). Пересборка
    /// движка стоит ~150 мс — это дешевле, чем оранжевая точка, висящая после вставки:
    /// горящий индикатор читается как «микрофон не выключается».
    private static let micReleaseDelay: TimeInterval = 0.5

    @Published public private(set) var state: DictationState = .idle
    /// Сколько диктовок записано и ещё не доехало до поля ввода: идущая обработка плюс
    /// очередь за ней. Живая запись сюда не входит — она ещё пишется, а не обрабатывается.
    /// Этим числом панель показывает вторую занятость, и оно же упирается в `maxPending`.
    @Published public private(set) var pendingCount = 0
    /// Последняя диктовка после слоя 2 и GPT-чистки, до перевода (для действий меню).
    @Published public private(set) var lastOriginal: String?
    /// Английский перевод последней диктовки: вставленный или сделанный по запросу из меню.
    @Published public private(set) var lastTranslation: String?
    /// Язык диктовки, которую панель сейчас называет: живой записи, если она есть, иначе
    /// первой в очереди обработки. Переключение языка на живой записи меняет настройку,
    /// но не саму диктовку — UI показывает отсюда, чтобы флаг не врал про то, чем на самом
    /// деле распознаётся речь. `nil` — дел нет, показываем `settings.language`.
    @Published public private(set) var activeSessionLanguage: Language?
    /// Перевод, назначенный этой диктовке хоткеем (правый ⌥), — он сильнее настройки.
    /// `nil` — переопределения нет, решает `settings.translateToEnglish` (в том числе прямо
    /// на стопе: обычную сессию тумблер меню меняет и на живой записи).
    @Published public private(set) var activeSessionTranslate: Bool?

    /// Текст, которому не нашлось поля ввода, — его забирает стопка карточек в приложении.
    /// Замыкание, а не `@Published`: ядро остаётся без UI, а карточка должна появиться
    /// ровно один раз на диктовку, а не на каждую пересборку подписчика.
    /// Возвращает `false`, если карточку показать не удалось, — тогда конвейер вставляет
    /// текст обычным путём. Не назначен — конвейер вставляет по-старому (так живёт CLI).
    public var onCardText: ((String) -> Bool)?

    /// Короткие сообщения, для которых пилюля занята более срочным. Не назначен — сообщения
    /// не показываются (так живёт CLI), и на работу конвейера это никак не влияет.
    public var onNotice: ((DictationNotice) -> Void)?

    private let gate: EngineGate
    private let dictionary: UserDictionary
    private let settings: AppSettings
    private let history: HistoryStore
    private let recordings: RecordingStore
    private let learner: EditLearner
    private let watcher: EditWatcher
    private let recorder: AudioCapturing
    private let delivery: TextDelivery
    private let makeVad: @Sendable () async throws -> SpeechGating
    private let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Dictation")

    private var vad: SpeechGating?

    /// Диктовка, которая пишется прямо сейчас. `nil` — микрофон свободен.
    private var recording: DictationSession?
    /// Записанные диктовки в порядке речи. Первая — та, что обрабатывается сейчас; из
    /// очереди она уходит только после вставки, поэтому и потолок, и счётчик занятости,
    /// и решение «достанется ли ей пилюля» считают её незавершённой.
    private var pending: [DictationSession] = []
    /// Работник очереди. Ровно один: порядок вставки обязан быть порядком речи.
    private var queueTask: Task<Void, Never>?

    /// Что хочет показать каждая из трёх сторон. Пилюля одна, и `publish()` выбирает из них
    /// по приоритету — иначе запись и обработка затирали бы друг друга по очереди.
    private var recordingState: DictationState?
    private var processingState: DictationState?
    private var flashState: DictationState?

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

    /// Подтверждённая фоном часть живой записи. Не private: тест отмены проверяет напрямую,
    /// что проход отменённой диктовки сюда не доезжает (как и подмена сообщения
    /// в `message(for:)`).
    var confirmedText: String { recording?.confirmedText ?? "" }
    var confirmedEndSample: Int { recording?.confirmedEndSample ?? 0 }

    private var chunks: AsyncStream<[Float]>.Continuation?
    private var vadTask: Task<Void, Never>?
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
        makeVad: @escaping @Sendable () async throws -> SpeechGating = { try await VadGate() },
        // Записи диктовок. Тесты подставляют сюда временную папку: класть настоящий голос
        // пользователя рядом с прогоном — не то, что тесты вправе делать.
        recordings: RecordingStore = .shared
    ) {
        self.gate = EngineGate(engine)
        self.dictionary = dictionary
        self.settings = settings
        self.history = .shared
        self.recordings = recordings
        self.learner = .shared
        self.watcher = .shared
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
                    if self.recording != nil { return }
                    self.recorder.setInputDevice(uid: uid)
                }
            }
    }

    // MARK: - Вход хоткеев

    /// `translating` назначает переводом всю сессию поверх настройки; `nil` — как раньше,
    /// решает `settings.translateToEnglish`. На остановке (и на отмене загрузки) параметр
    /// не смотрим вовсе: остановить и отменить запись вправе любой хоткей, а решение
    /// о переводе принято при её старте.
    ///
    /// Смотрим строго на живую запись, а не на общее состояние: пока предыдущая диктовка
    /// доезжает, хоткей обязан начинать новую, а не ждать конца конвейера. Ровно в этом
    /// наложение и состоит.
    public func toggle(translating: Bool? = nil) {
        switch recordingState {
        case .recording:
            stopAndProcess()
        case .preparingModel:
            // Первая загрузка модели идёт минутами — хоткей отменяет сессию, а не ждёт впустую.
            pendingCancel = true
        case nil:
            begin(translating: translating)
        default:
            break  // других состояний у записи не бывает
        }
    }

    /// Esc снимает ИДУЩУЮ ЗАПИСЬ: записанное выбрасывается целиком — ни распознавания,
    /// ни вставки, ни истории, ни «последней диктовки».
    ///
    /// Уже записанные диктовки Esc не трогает, даже если они всё ещё считаются. Так решено
    /// осознанно: они почти доехали, и выбросить готовую работу обиднее, чем недоотменить.
    /// К тому же при наложении Esc всегда означает «эту, которую я сейчас говорю» — одна
    /// клавиша с двумя смыслами («сними запись» и «сними очередь») была бы ловушкой.
    ///
    /// Чайм остановки здесь намеренно не играем: он означает «записал, обрабатываю»,
    /// а отмена — это «ничего не было». Тишина честнее звука.
    public func cancelDictation() {
        switch recordingState {
        case .recording:
            discardRecording()
        case .preparingModel:
            // Тот же путь, что у второго хоткея: саму загрузку прервать нечем, но записи
            // после неё не будет. Разница одна — Esc мигает отменой на любом шаге, иначе
            // непонятно, дошло нажатие или нет.
            pendingCancel = true
            pendingCancelFlashes = true
        default:
            break  // записи нет — отменять нечего
        }
    }

    public func switchLanguage() {
        // Язык записи от этого не меняется (см. `activeSessionLanguage`), но потоковый путь
        // должен быть гарантированно однородным — на живой записи просто выключаем его.
        recording?.languageSwitched = true
        // По кругу в порядке `Language.allCases`: русский → украинский → English → русский.
        // Один и тот же порядок в меню, в настройках и под хоткеем — иначе третий язык
        // превратил бы шорткат в лотерею.
        let all = Language.allCases
        let index = all.firstIndex(of: settings.language) ?? 0
        settings.language = all[(index + 1) % all.count]
    }

    /// Прогон файла для CLI: VAD-обрезка → Whisper → словарь → (опционально) GPT. Без вставки и истории.
    public func process(fileSamples: [Float], language: Language, useGPT: Bool) async throws -> String {
        defer {
            processingState = nil
            publish()
        }

        try await gate.prepare(language: language) { [weak self] modelState in
            Task { @MainActor in self?.apply(modelState) }
        }
        let vad = try await ensureVad()
        let leveled = AudioNormalizer.normalized(fileSamples)
        guard let speech = try await vad.trimmed(leveled) else { throw DictationError.noSpeech }

        let entries = dictionary.entries
        processingState = .transcribing
        publish()
        let raw = try await gate.transcribe(
            speech,
            language: language,
            prompt: PromptBuilder.initialPrompt(entries: entries, language: language)
        )
        let text = ReplacementEngine.apply(raw, entries: entries)
        guard useGPT else { return text }

        processingState = .cleaning
        publish()
        return try await PostProcessor.cleanup(
            text: text,
            entries: entries,
            language: language,
            config: settings.gptConfig,
            restoreUkrainianInserts: settings.restoreUkrainianInserts
        )
    }

    // MARK: - Запись

    private func begin(translating: Bool?) {
        guard !isStarting else { return }  // старт уже идёт — второй хоткей игнорируем
        // Потолок очереди. Отказ обязан быть слышен: молча не начать запись — худшее, что
        // диктовка может сделать, потому что человек говорит в никуда и узнаёт об этом
        // только через минуту. Отсюда записка рядом с панелью — и ни звука старта.
        guard pending.count < Self.maxPending else {
            logger.notice("Очередь заполнена (\(Self.maxPending, privacy: .public)) — новая диктовка не начата")
            onNotice?(.queueFull(limit: Self.maxPending))
            return
        }
        isStarting = true
        // Чайм старта — здесь, а не перед самой записью, и это его смысл: он отвечает
        // «нажатие принято», а не «микрофон уже слышит». Ухо к задержке чувствительнее
        // глаза: путь от хоткея до живого микрофона занимает 19–70 мс (замерено), и капсула
        // на этом фоне мгновенная, а чайм, стоявший в самом конце, всё равно опаздывал.
        // Заодно его хвост больше не попадает в запись — раньше это подчищал VAD.
        //
        // Цена одна и редкая: на первой диктовке после запуска модель может быть холодной,
        // и тогда чайм прозвучит раньше, чем начнётся запись. Капсула в этот момент прямо
        // говорит «Готовлю модель…», так что обмана не выходит.
        if settings.soundsEnabled { SoundPlayer.shared.playStart() }
        // Отмена прошлой записи новую не трогает — все её флаги снимаем на старте.
        pendingCancel = false
        pendingCancelFlashes = false

        idleTask?.cancel()
        idleTask = nil
        micReleaseTask?.cancel()
        micReleaseTask = nil
        prewarmGPT()

        let session = DictationSession(language: settings.language, translating: translating)
        recording = session
        publish()
        Task {
            defer { isStarting = false }
            do {
                try await gate.prepare(language: session.language) { [weak self] modelState in
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
                try await startCapture(session)
            } catch {
                recording = nil
                recordingState = nil
                publish()
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

    private func startCapture(_ session: DictationSession) async throws {
        // Страховка от хвостов прошлой записи: осиротевший VAD-цикл крутился бы вечно.
        // Фоновые проходы здесь не трогаем — они принадлежат своей диктовке и живут ровно
        // столько, сколько она: их снимает её стоп, а не старт следующей.
        vadTask?.cancel()
        vadTask = nil
        chunks?.finish()
        chunks = nil

        session.prompt = PromptBuilder.initialPrompt(
            entries: dictionary.entries,
            language: session.language
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
        recordingState = .recording(live: "", level: 0)
        publish()
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
        startRollingLoop(session)
        offerParallelHintIfDue()
    }

    /// Разовая подсказка про наложение — один раз за всю жизнь приложения: второй раз это
    /// уже не новость, а помеха. Работу она не блокирует и фокус не забирает: это записка
    /// рядом с панелью, а не диалог.
    private func offerParallelHintIfDue() {
        guard !settings.parallelHintShown else { return }
        settings.dictationsStarted += 1
        guard settings.dictationsStarted >= Self.parallelHintAt else { return }
        settings.parallelHintShown = true
        onNotice?(.parallelHint)
    }

    /// Фоновая финализация: пока идёт запись, большая модель переписывает весь накопленный
    /// буфер и подтверждает всё, кроме последнего сегмента. К стопу остаётся распознать
    /// только хвост, а не десять секунд заново.
    ///
    /// Проходы стоят в общей очереди `EngineGate` — WhisperKit-инстанс один, и финальный
    /// хвост всё равно дождётся идущего прохода. Никакого состояния UI цикл не трогает.
    private func startRollingLoop(_ session: DictationSession) {
        session.rollingTask = Task { [weak self] in
            while true {
                // Потоковый путь уже снят (упавший проход, переключённый язык) — жечь на него
                // ANE до конца записи незачем. Тождество диктовки заодно и есть признак
                // «запись ещё идёт»: стоп и отмена отпускают `recording`.
                guard let self, self.recording === session,
                      !session.rollingFailed, !session.languageSwitched
                else { return }

                // Пока предыдущая диктовка не доехала, фоновые проходы молчат: инстанс
                // WhisperKit один, и проход по растущему буферу отодвинул бы её вставку —
                // а ждут сейчас именно её, свою будущую человек ещё договаривает.
                guard self.pending.isEmpty else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.rollingPoll * 1_000_000_000))
                    continue
                }

                // Опрашиваем длину, а не сам буфер: снимок массива стоит копии по записи
                // на аудиопотоке. Дальше потолка новые проходы не стартуют вовсе.
                let captured = self.recorder.capturedSampleCount
                guard captured <= Self.rollingMaxSamples else { return }
                // До порога потокового пути проходы бессмысленны и вредны: короткая диктовка
                // всё равно пойдёт полным проходом, а идущий проход стоп обязан дождаться —
                // это была бы чистая потеря там, где скорость важнее всего.
                guard captured >= Self.streamingMinSamples,
                      captured - session.rollingPassSamples >= Self.rollingGrowth
                else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.rollingPoll * 1_000_000_000))
                    continue
                }

                // Тот же подъём уровня, что и на финале: фоновый проход обязан слышать
                // ровно то же, что услышит хвост, иначе подтверждённая часть и склейка
                // считаются по разному звуку.
                let samples = AudioNormalizer.normalized(self.recorder.capturedSamples)
                session.rollingPassSamples = samples.count

                do {
                    let segments = try await self.gate.transcribeSegments(
                        samples,
                        language: session.language,
                        prompt: session.prompt
                    )
                    session.confirm(segments)
                } catch {
                    // Один упавший проход — и весь потоковый путь снят: финал пойдёт полным
                    // проходом, как раньше. Оптимизация не имеет права быть риском.
                    session.rollingFailed = true
                    self.logger.error(
                        "Фоновый проход не удался: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }

                // Передышку берём только на живой записи: стоп ждёт эту задачу, и лишний сон
                // после уже посчитанного прохода был бы прямой задержкой финала.
                guard self.recording === session else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.rollingGap * 1_000_000_000))
            }
        }
    }

    private func append(_ chunk: [Float]) {
        guard isRecording else { return }
        chunks?.yield(chunk)
    }

    private func updateLevel(_ value: Float) {
        guard isRecording else { return }
        recordingState = .recording(live: "", level: value)
        publish()
    }

    /// Идёт ли прямо сейчас запись с микрофона — в отличие от подготовки модели перед ней
    /// и от обработки уже записанного.
    private var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
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
        guard isRecording else { return }
        stopAndProcess()
    }

    /// Захват сорвался на живой записи: микрофон не отдал ни одного блока, устройство
    /// исчезло, сессию прервали. Записанное до сбоя не выбрасываем — если там есть что
    /// распознавать, идём обычным стопом; если нет, честно говорим о микрофоне вместо
    /// бессмысленного «речь не обнаружена».
    private func captureFailed(_ reason: String) {
        guard let session = recording, isRecording else { return }
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
        session.rollingTask?.cancel()
        session.cancelled = true
        recording = nil
        recordingState = nil
        recorder.onLevel = nil
        recorder.onFailure = nil
        _ = recorder.stop()
        scheduleMicRelease()
        publish()
        fail(reason)
    }

    /// Стоп: диктовка снимается с микрофона и уезжает в очередь обработки, а контроллер тем
    /// же движением освобождается для следующей. Ровно в этом наложение и состоит.
    private func stopAndProcess() {
        guard let session = recording else { return }
        chunks?.finish()
        chunks = nil
        vadTask?.cancel()
        vadTask = nil
        // Отмена не прерывает идущий проход (он живёт своей задачей в `EngineGate`),
        // зато снимает передышку между проходами — иначе финал ждал бы её впустую.
        session.rollingTask?.cancel()
        recorder.onLevel = nil
        recorder.onFailure = nil

        session.samples = recorder.stop()
        session.capturedSilence = recorder.capturedSilence
        session.translatesToEnglish = session.translating ?? settings.translateToEnglish
        // Микрофон дальше не нужен: распознавание и GPT-чистка занимают секунды, и всё это
        // время индикатор записи гореть не должен. Диктовки подряд ничего не теряют —
        // `begin()` снимает этот таймер первым делом.
        scheduleMicRelease()
        if settings.soundsEnabled { SoundPlayer.shared.playStop() }

        recording = nil
        recordingState = nil
        pending.append(session)
        // Стадию ставим синхронно со стопом, а не первым шагом работника: между ними
        // проходит целый тик, и панель успела бы мигнуть простоем — то есть спрятаться
        // и тут же вернуться. Работник поставит её ещё раз, это ничего не стоит.
        if processingState == nil { processingState = .transcribing }
        publish()
        drainQueue()
    }

    /// Отмена на живой записи: захват сворачиваем так же, как на обычном стопе, но буфер
    /// выбрасываем — он никуда не уезжает, поэтому и бэкап-WAV писать незачем. Очередь
    /// обработки при этом не трогаем совсем: там чужие, уже сказанные диктовки.
    private func discardRecording() {
        guard let session = recording else { return }
        chunks?.finish()
        chunks = nil
        vadTask?.cancel()
        vadTask = nil
        // Идущий фоновый проход не прерывается: `EngineGate` отмену не смотрит, а WhisperKit
        // не умеет её вовсе — он досчитает в никуда, как и загрузка модели на отмене.
        // Флаг делает его результат заведомо мёртвым: `confirm` отбросит сегменты, даже
        // если они придут раньше, чем начнётся следующая запись.
        session.rollingTask?.cancel()
        session.cancelled = true
        recording = nil
        recordingState = nil
        recorder.onLevel = nil
        recorder.onFailure = nil
        _ = recorder.stop()
        // Микрофон отпускаем по обычному расписанию: отмена — не повод держать индикатор
        // записи, но и не повод рвать прогрев для следующей диктовки.
        scheduleMicRelease()
        publish()
        cancelled()
    }

    // MARK: - Очередь обработки

    /// Разбирает очередь строго по одной диктовке и строго в порядке речи.
    ///
    /// Порядок здесь — не свойство реализации, а требование: если вторая диктовка
    /// распозналась быстрее первой и вставилась раньше, предложения меняются местами,
    /// и функция из полезной становится вредной. Один работник — самый дешёвый способ это
    /// гарантировать, и он ничего не стоит: инстанс WhisperKit всё равно один, так что
    /// параллельные проходы дали бы не скорость, а толкотню.
    private func drainQueue() {
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            while true {
                guard let self, let session = self.pending.first else { break }
                let result = await self.process(session)
                // Снимаем с очереди только теперь: пока диктовка в `pending`, она считается
                // необработанной — и для потолка, и для счётчика занятости, и для решения,
                // достанется ли её итогу пилюля.
                self.pending.removeFirst()
                // Очередь не опустела — следующая диктовка начинается прямо сейчас, и стадия
                // обязана смениться в том же такте: пустой промежуток панель показала бы
                // простоем и спрятала бы пилюлю между двумя диктовками.
                self.processingState = self.pending.isEmpty ? nil : .transcribing
                self.publish()
                self.flashResult(result.state, linger: result.linger)
            }
            self?.queueTask = nil
        }
    }

    /// Обрабатывает одну записанную диктовку и возвращает итог для панели. Доводить итог
    /// до экрана — дело очереди: только она знает, стоит ли за этой диктовкой следующая.
    private func process(_ session: DictationSession) async -> (state: DictationState, linger: TimeInterval) {
        let samples = session.samples
        let language = session.language
        // Бэкап уходит в фон и не ждётся: кодирование и запись WAV длинной диктовки —
        // это сотни миллисекунд ровно перед распознаванием, то есть чистая задержка.
        // На диск ложится исходная запись, без подъёма уровня: архив обязан быть тем,
        // что и правда сказали в микрофон.
        let backup = startBackup(samples)
        // Уровень поднимаем один раз на всю запись и дальше работаем только с поднятым:
        // и ворота речи, и Whisper обязаны слышать одно и то же (см. `AudioNormalizer`).
        let leveled = AudioNormalizer.normalized(samples)
        // Идущий фоновый проход обязателен к ожиданию: он и досчитывает подтверждённую часть,
        // и в любом случае занимает единственный инстанс WhisperKit. Задачу берём у самой
        // диктовки — на микрофоне к этому моменту может писаться уже следующая, со своей.
        await session.rollingTask?.value
        session.rollingTask = nil

        processingState = .transcribing
        publish()
        do {
            let entries = dictionary.entries
            // Решение о переводе принято на стопе — здесь его только исполняем.
            let wantsTranslation = session.translatesToEnglish
            let raw: String
            /// Уверенность распознавания по словам — из того же прохода, что и текст.
            var heardWords: [WordProbe] = []
            // Звук, которому соответствует текст: потоковый путь собирает его по всей
            // записи, обычный — по обрезанной. Второму мнению нужен именно он, иначе
            // таймкоды фраз указывали бы не туда.
            let heard: [Float]
            if let streamed = await streamedTranscript(session, samples: leveled) {
                raw = streamed
                heard = leveled
                heardWords = session.confirmedWords + session.tailWords
            } else {
                let vad = try await ensureVad()
                guard let speech = try await vad.trimmed(leveled) else {
                    throw DictationError.noSpeech
                }
                let pass = try await gate.transcribeDetailed(
                    speech, language: language, prompt: session.prompt
                )
                raw = pass.text
                heardWords = pass.words
                heard = speech
            }
            // Сломанные куски — те, где распознаватель шёл неуверенно несколько слов подряд
            // (см. `Uncertainty`). Ими решаются сразу два вопроса: что сказать человеку и
            // стоит ли платить за сверку соседним языком.
            let shaky = Uncertainty.runs(in: heardWords)
            // Единственное место, где текст диктовки уже собран целиком, — здесь. Проверка
            // соседнего языка обязана стоять именно тут: внутри распознавания она видела бы
            // только хвост длинной диктовки (см. `WhisperEngine.reconsideringNeighbour`).
            //
            // И только когда есть что перечитывать. Проверка стоит лишнего полного прохода
            // плюс трети секунды на каждый кусок — раньше это платила КАЖДАЯ диктовка, в том
            // числе чистейший русский, где перечитывать нечего (замерено: 2,6 с против 4,9 с
            // на девятисекундной записи). Пословная уверенность бесплатна и закрывает ворота
            // там, где ломаться нечему.
            let checked = shaky.isEmpty
                ? NeighbourPass(text: raw)
                : await gate.reconsideringNeighbour(
                    raw, samples: heard, language: language, prompt: session.prompt
                )
            var text = ReplacementEngine.apply(checked.text, entries: entries)
            var degradations: [String] = []
            // О беде говорим вслух и АДРЕСНО. Гладкая фраза опаснее явного мусора: мусор
            // человек видит и переговаривает, а складную — принимает на веру, даже если
            // распознавание потеряло в ней отрицание. Безадресное «фраза перечитана» этой
            // работы не делает: искать, куда смотреть, всё равно приходится самому.
            if let alarm = Uncertainty.alarm(runs: shaky, reread: checked.phrases) {
                degradations.append(alarm)
            }
            var translation: String?
            let skipsGPT = ShortDictation.skipsGPT(
                text: text,
                enabled: settings.skipGPTForShort,
                wordLimit: settings.shortDictationWordLimit,
                translating: wantsTranslation
            )

            if settings.gptEnabled, !skipsGPT {
                processingState = .cleaning
                publish()
                do {
                    // Английский к этому моменту уже есть — от GPT нужна только чистка.
                    // Модель всё равно берём переводческую: вызов принадлежит переводу,
                    // и правила у него свои.
                    let processed = try await PostProcessor.cleanup(
                        text: text,
                        entries: entries,
                        language: language,
                        config: wantsTranslation ? settings.translateGPTConfig : settings.gptConfig,
                        translateToEnglish: wantsTranslation,
                        restoreUkrainianInserts: settings.restoreUkrainianInserts
                    )
                    if wantsTranslation {
                        translation = processed
                    } else {
                        text = processed
                    }
                } catch {
                    // Слой 3 не обязателен: отдаём результат слоя 2 и говорим об этом.
                    // При переводе тем же вызовом теряется и чистка — говорим об обоих.
                    // Перевод к этому моменту уже сделан моделью — теряется только чистка.
                    degradations.append("без AI-чистки: \(error.localizedDescription)")
                    logger.error("GPT-слой не отработал: \(error.localizedDescription, privacy: .public)")
                }
            } else if wantsTranslation {
                degradations.append("без перевода")
            }

            // GPT перевод не сделал — переводит сама модель. Качество у GPT выше, поэтому
            // он и остаётся первым; но перевод просили клавишей, и молча отдать русский
            // текст вместо английского нельзя. Стоит это одного лишнего прохода по записи
            // и только в том случае, когда GPT недоступен.
            if wantsTranslation, translation == nil {
                if let local = await localTranslation(of: leveled, session: session, language: language) {
                    translation = local
                    degradations.append("перевод без ChatGPT — качество ниже")
                } else {
                    degradations.append("перевод не удался")
                }
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
            // Поле ввода ищется ровно здесь — то есть то, в котором фокус на момент
            // готовности текста, а не на момент, когда его наговорили. При наложении это
            // и есть нужное поведение: человек мог за это время перейти в другое окно.
            let destination = await deliver(output)
            let saved = await backup.value
            history.add(output, language: language, audio: saved?.name, seconds: saved?.seconds)
            // Словарь учится на правках человека, а не на догадках по виду слова. Если текст
            // действительно уехал в поле, берём это поле под наблюдение: что человек в нём
            // поправит, то и есть настоящая ошибка распознавания. В карточке и в буфере
            // обмена наблюдать нечего — там никто ничего не правит.
            if case .pasteboard(.pasted) = destination {
                watchEdits(of: output)
            }

            if case .pasteboard(.clipboardOnly(let reason)) = destination {
                degradations.append(Self.clipboardMessage(reason))
            }
            // Речи на выходе подозрительно мало для такой длинной записи. Молчать об этом
            // нельзя: именно так и выглядит потерянная диктовка — текст вроде есть, а половины
            // сказанного в нём нет, и заметить это можно только по памяти.
            if TranscriptQuality.looksTruncated(text: output, seconds: saved?.seconds) {
                logger.error(
                    """
                    Мало текста на \(saved?.seconds ?? 0, format: .fixed(precision: 0)) c записи: \
                    \(ShortDictation.wordCount(output), privacy: .public) слов
                    """
                )
                degradations.append("распознано мало для записи — «История…» даст распознать заново")
            }
            // Оговорка про AI-чистку не должна съедать главную новость: текст не в документе,
            // а в карточке — без этого пользователь пойдёт искать его не там.
            if case .card = destination, !degradations.isEmpty {
                degradations.append("текст в карточке")
            }
            if !degradations.isEmpty {
                return (.degraded(degradations.joined(separator: "; ")), Self.degradedLinger)
            }
            switch destination {
            case .card: return (.carded, Self.insertedLinger)
            case .pasteboard: return (.inserted, Self.insertedLinger)
            }
        } catch {
            // Текста нет, но запись есть — и это главное, что человеку сейчас нужно знать.
            // Пустая строка в истории существует ровно затем, чтобы к звуку вела дверь.
            let saved = await backup.value
            if let saved {
                history.addFailed(language: language, audio: saved.name, seconds: saved.seconds)
            }
            let text = message(for: error, recorded: saved != nil, silence: session.capturedSilence)
            return (.error(text), Self.errorLinger)
        }
    }

    /// «Речь не обнаружена» на цифровой тишине — неправда: молчал не человек, а микрофон
    /// (так ведёт себя мёртвый HFP-вход Bluetooth-гарнитуры). Говорим то, что помогает.
    ///
    /// А если запись сохранилась — главная новость не в том, что распознать не вышло,
    /// а в том, что сказанное не пропало и его можно разобрать заново.
    ///
    /// `silence` — снимок, снятый на стопе именно этой диктовки: без него опрос захвата
    /// при наложении ответил бы про следующую запись. `nil` — спросить захват (так зовут
    /// снаружи, где снимка нет).
    /// Не private: подмена сообщения проверяется тестом напрямую.
    func message(for error: Error, recorded: Bool = false, silence: Bool? = nil) -> String {
        guard error is DictationError else { return error.localizedDescription }
        if silence ?? recorder.capturedSilence {
            return "микрофон молчит — выберите другой вход в меню «Микрофон»"
        }
        guard recorded else { return error.localizedDescription }
        return "речь не обнаружена — запись сохранена, распознайте заново в «Истории…»"
    }

    /// Финал по потоковому пути: подтверждённая фоном часть уже распознана, осталось
    /// декодировать хвост от `confirmedEndSample` (с нахлёстом назад) и склеить.
    ///
    /// `nil` — путь неприменим или не дал результата; вызывающий код идёт обычным полным
    /// проходом. Это железное правило: ускорение не имеет права стать риском для текста.
    private func streamedTranscript(_ session: DictationSession, samples: [Float]) async -> String? {
        guard !session.rollingFailed,                            // фоновый проход падал
              !session.languageSwitched,                         // язык переключали на записи
              samples.count >= Self.streamingMinSamples,         // диктовка короче 6 с
              session.confirmedEndSample > 0,                    // подтверждать нечего
              !session.confirmedText.isEmpty,
              session.confirmedEndSample < samples.count
        else { return nil }

        do {
            let start = max(0, session.confirmedEndSample - Self.tailOverlap)
            // Буфер целиком не обрезаем: подтверждённые сегменты уже без ведущей тишины —
            // её отрезали таймкоды Whisper. Тем же гейтом снимаем тишину по краям хвоста.
            let vad = try await ensureVad()
            guard let tail = try await vad.trimmed(Array(samples[start...])) else { return nil }

            let tailPass = try await gate.transcribeDetailed(
                tail,
                language: session.language,
                prompt: session.prompt
            )
            let tailText = tailPass.text
            // Пустой хвост — не «там была тишина», а признак того, что проход не удался
            // (например, окно короче внутреннего `windowClipTime` WhisperKit). Слова терять
            // нельзя, поэтому откатываемся на полный проход.
            guard !tailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            session.tailWords = tailPass.words
            return StreamingMerge.merge(confirmed: session.confirmedText, tail: tailText)
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
        guard recordingState == nil, processingState == nil else { return }
        flashState = .degraded(message)
        publish()
        scheduleIdle(after: Self.flashLinger)
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

    /// Взять поле под наблюдение и, если человек что-то поправит, доучить словарь.
    private func watchEdits(of text: String) {
        watcher.watch(inserted: text) { [weak self] corrections in
            Task { @MainActor in await self?.learn(corrections, sentence: text) }
        }
    }

    /// Судьба замеченных правок: спрашиваем GPT, что из этого ошибка распознавания.
    ///
    /// Приложение само решить не может. Отличить исправление нашего текста от начала
    /// собственной работы человека можно только по смыслу, поэтому наблюдение копит ВСЁ,
    /// что нашлось за окно, а решает один запрос на всю пачку — с временем появления
    /// каждой пары.
    ///
    /// Наружу уходят пары слов, а не снимки поля: снимок — это весь текст человека,
    /// включая написанное после нашего, и выносить такое ради двух слов нельзя.
    ///
    /// Судья не обязателен: GPT выключен или не ответил — возвращаемся к прежнему правилу
    /// с повторением. Молча класть в словарь непроверенное нельзя: лишняя пара портит ВСЕ
    /// будущие диктовки, а пропущенную человек добавит руками.
    private func learn(_ found: [ObservedCorrection], sentence: String) async {
        let corrections = found.map(\.correction)
        guard settings.gptEnabled,
              let verdicts = await DictionaryJudge.verdicts(
                  on: found,
                  sentence: sentence,
                  language: settings.language,
                  config: settings.gptConfig
              ),
              verdicts.count == corrections.count
        else {
            logger.notice("Правки: судьи нет — идут прежним путём, через повторение")
            let learned = learner.observe(corrections, entries: dictionary.entries)
            apply(learned)
            return
        }

        var approved: [Correction] = []
        for (correction, verdict) in zip(corrections, verdicts) {
            logger.notice(
                """
                Правка \(correction.heard, privacy: .public) → \(correction.meant, privacy: .public): \
                \(verdict.learn ? "берём" : "не берём", privacy: .public) (\(verdict.reason, privacy: .public))
                """
            )
            if verdict.learn { approved.append(correction) }
        }
        apply(approved.map { learner.accept($0, entries: dictionary.entries) })
    }

    /// Положить готовые статьи в словарь, не заведя дубля.
    private func apply(_ learned: [DictionaryEntry]) {
        guard !learned.isEmpty else { return }
        var entries = dictionary.entries
        for entry in learned {
            // Статья могла быть существующей — тогда у неё просто прибавился вариант.
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        dictionary.replace(entries: entries)
        for entry in learned {
            logger.notice("словарь пополнен правкой: \(entry.canonical, privacy: .public)")
        }
    }

    /// Перевод силами самой модели: у Whisper это вторая задача декодера, не второй вызов
    /// сети. Нужен ровно тогда, когда GPT недоступен, — и тем и ценен, что работает без
    /// сети и без входа в ChatGPT.
    private func localTranslation(
        of leveled: [Float],
        session: DictationSession,
        language: Language
    ) async -> String? {
        do {
            let vad = try await ensureVad()
            guard let speech = try await vad.trimmed(leveled) else { return nil }
            let english = try await gate.transcribe(
                speech,
                language: language,
                prompt: session.prompt,
                translating: true
            )
            let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            logger.error("перевод моделью не удался: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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

    /// Сводит три стороны в одну пилюлю. Приоритет: живая запись сильнее обработки, обработка
    /// сильнее итоговой вспышки. Порядок именно такой, потому что пилюля обязана показывать
    /// самое срочное: пока человек говорит, ему нужны уровень звука и «esc», а не рассказ
    /// о том, что доехало полминуты назад.
    private func publish() {
        state = recordingState ?? processingState ?? flashState ?? .idle
        pendingCount = pending.count
        // Флаг языка и метка перевода — про ту диктовку, которую пилюля сейчас называет.
        if let recording {
            activeSessionLanguage = recording.language
            activeSessionTranslate = recording.translating
        } else if let next = pending.first {
            activeSessionLanguage = next.language
            activeSessionTranslate = next.translatesToEnglish
        } else {
            activeSessionLanguage = nil
            activeSessionTranslate = nil
        }
    }

    /// Показывает итог диктовки — или, если пилюля занята более срочным, отправляет его
    /// запиской рядом с панелью.
    ///
    /// Молчать нельзя: отмена, оговорка и сбой — ровно то, о чём человек обязан узнать.
    /// А «вставлено» и «в карточку» говорят сами за себя: текст уже на экране.
    private func flashResult(_ result: DictationState, linger: TimeInterval) {
        guard recordingState == nil, pending.isEmpty else {
            switch result {
            case .cancelled, .degraded, .error:
                onNotice?(.result(result))
            case .idle, .preparingModel, .recording, .transcribing, .cleaning, .inserted, .carded:
                break
            }
            return
        }
        flashState = result
        publish()
        scheduleIdle(after: linger)
    }

    private func apply(_ modelState: ASRModelState) {
        switch modelState {
        case .downloading(let progress):
            showPreparing(.downloading(progress))
        case .loading:
            startWarming()
        case .notLoaded, .ready:
            break
        }
    }

    /// Подготовка модели принадлежит тому, кто её заказал: живой записи, если она есть,
    /// иначе внеочередному разбору (повтор из истории, прогон файла в CLI).
    private func showPreparing(_ preparation: ModelPreparation) {
        if recording != nil {
            recordingState = .preparingModel(preparation)
        } else {
            processingState = .preparingModel(preparation)
        }
        publish()
    }

    /// Отметку времени ставим один раз на весь прогрев: `apply(.loading)` приходит и по
    /// нескольку раз, а счётчик секунд в панели не должен от этого прыгать на ноль.
    private func startWarming() {
        if case .some(.preparingModel(.warming)) = recordingState { return }
        if case .some(.preparingModel(.warming)) = processingState { return }
        showPreparing(.warming(since: Date()))
    }

    private func ensureVad() async throws -> SpeechGating {
        if let vad { return vad }
        startWarming()
        let created = try await makeVad()
        vad = created
        return created
    }

    /// Сбой показываем как есть: черновика больше нет (live-превью убрано вместе с панелью
    /// текста), а сама запись лежит в бэкапе.
    private func fail(_ message: String) {
        flashResult(.error(message), linger: Self.errorLinger)
    }

    /// Вспышка «отменено» и возврат в простой. Отдельно от `fail`: отмена — не сбой.
    private func cancelled() {
        flashResult(.cancelled, linger: Self.cancelledLinger)
    }

    /// Сессию отменили хоткеем на загрузке модели (Whisper или VAD): записи не было,
    /// поэтому тихо возвращаемся в простой — без сообщения об ошибке.
    private func cancelSession() {
        let flashes = pendingCancelFlashes
        pendingCancel = false
        pendingCancelFlashes = false
        recording?.cancelled = true
        recording = nil
        recordingState = nil
        publish()
        // Отмену по Esc показываем так же, как на записи: `cancelled()` сам вернёт
        // в простой и отпустит микрофон через `scheduleIdle`.
        guard !flashes else {
            cancelled()
            return
        }
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
            self.flashState = nil
            self.publish()
            self.scheduleMicRelease()
        }
    }

    /// Микрофон отпускаем почти сразу после возврата в простой: индикатор записи не должен
    /// гореть после вставки. Задержка в 0.5 c только склеивает диктовки, идущие подряд.
    private func scheduleMicRelease() {
        micReleaseTask?.cancel()
        micReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.micReleaseDelay * 1_000_000_000))
            // Пока таймер тикал, могла начаться следующая запись — отбирать у неё микрофон
            // нельзя: при наложении конец одной диктовки и начало другой почти совпадают.
            guard !Task.isCancelled, let self, self.recording == nil else { return }
            self.recorder.teardown()
        }
    }

    /// Кодирование и запись WAV — вне главного потока и вне критического пути. `samples`
    /// уезжает в задачу значением (массив уже никто не меняет), поэтому снимок консистентен.
    /// О сбое `RecordingStore` сообщает сам и отдаёт nil: бэкап — страховка, и ронять
    /// из-за неё диктовку нельзя.
    private func startBackup(_ samples: [Float]) -> Task<RecordingStore.Saved?, Never> {
        let recordings = self.recordings
        let keeping = settings.keptRecordings
        return Task.detached(priority: .utility) {
            recordings.save(samples, keeping: keeping)
        }
    }

    // MARK: - Повторное распознавание

    /// Как разбирать запись во второй раз.
    ///
    /// Смысл повтора — пойти ДРУГИМ путём: тот же самый потеряет речь ровно там же.
    /// Поэтому здесь нет ни потоковой финализации со склейкой кусков по таймкодам,
    /// ни обрезки воротами речи, ни словарного промпта — а промпт, как показал замер,
    /// и есть главный вор слов (см. `WhisperEngine.maxPromptTokens`). Модель по умолчанию
    /// та же: «больше» для русского не значит «лучше» (см. `WhisperModel`).
    public enum RetranscribeMode: Sendable {
        /// Полный однопроходный разбор целого буфера на модели языка.
        case samePlainPass
        /// То же самое, но на large-v3. Дольше в разы и на русском часто хуже — выбор явный.
        case largeModel
    }

    /// Распознаёт сохранённую запись заново и возвращает текст (он же уезжает в историю).
    /// Модели `largeModel` может не быть на диске — тогда бросает, а качать её или нет,
    /// решает вызывающий: это 2,9 ГБ.
    public func retranscribe(item: HistoryItem, mode: RetranscribeMode) async throws -> String {
        guard let audio = item.audio else { throw RecordingStoreError.missing }
        let samples = try recordings.samples(named: audio)
        let language = item.language
        // Вариант модели и язык распознавания — разные вещи: large-v3 на повторе берётся
        // для того же языка, а не вместе с чужим.
        let variant = mode == .largeModel ? WhisperModel.large : language.whisperModel

        processingState = .transcribing
        publish()
        defer {
            processingState = nil
            publish()
            scheduleIdle(after: Self.insertedLinger)
        }

        try await gate.prepare(variant: variant, language: language) { [weak self] modelState in
            Task { @MainActor in self?.apply(modelState) }
        }
        // Ворота речи не зовём вовсе: на повторе честнее отдать модели всё, включая тишину,
        // чем во второй раз недосчитаться. Уровень поднимаем — это ровно то, чего тихой
        // записи не хватало в первый раз. Промпта нет: замер показал, что именно он и есть
        // главный вор слов (см. `WhisperEngine.maxPromptTokens`), а словарь всё равно
        // отработает слоем 2.
        let raw = try await gate.transcribe(
            AudioNormalizer.normalized(samples),
            language: language,
            variant: variant,
            prompt: ""
        )
        let text = ReplacementEngine.apply(raw, entries: dictionary.entries)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationError.noSpeech
        }
        history.replace(id: item.id, text: text)
        lastOriginal = text
        lastOriginalLanguage = item.language
        lastTranslation = nil
        delivery.copy(text)
        flashState = .inserted
        publish()
        return text
    }
}
