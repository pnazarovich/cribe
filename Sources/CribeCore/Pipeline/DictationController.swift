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
    /// `live` — склеенная бегущая строка (см. `LiveTranscript`). Пуста, пока слов меньше
    /// `DictationController.livePreviewMinimumWords` или пока в настройках выбрана волна.
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
/// Всё, что нужно, чтобы повторить не удавшуюся чистку. Текст здесь — результат слоя 2,
/// то есть ровно то, что чистка не осилила; `delivered` — то, что в итоге уехало в поле.
/// Второе нужно, чтобы решить, можно ли заменить текст на месте: заменять там, где человек
/// уже что-то дописал, нельзя.
public struct CleanupRetry: Sendable, Equatable {
    public let text: String
    public let delivered: String
    public let language: Language
    public let translating: Bool

    public init(text: String, delivered: String, language: Language, translating: Bool) {
        self.text = text
        self.delivered = delivered
        self.language = language
        self.translating = translating
    }
}

/// Чем кончился повтор чистки.
public enum CleanupRetryOutcome: Sendable, Equatable {
    /// Текст в поле заменён на чистый.
    case replaced
    /// Поле уже не наше (человек дописал или ушёл в другое окно) — чистый текст в буфере.
    case copied
    case failed(String)
}

extension CleanupRetry {
    /// Куда деть результат повтора: заменить текст в поле или отдать в буфер обмена.
    ///
    /// Заменять вслепую нельзя. Замена — это Cmd-A и Cmd-V, то есть «выделить ВСЁ поле
    /// и перезаписать»; если человек успел дописать своё или ушёл в другое окно, так
    /// теряется его работа. Поэтому поле перечитывается прямо здесь, непосредственно перед
    /// заменой, и должно содержать ровно то, что мы вставили. Всё остальное — в буфер.
    ///
    /// Отдельной функцией, а не строчками внутри контроллера, ровно затем, чтобы это решение
    /// можно было проверить тестами: поднимать ради него конвейер с записью и GPT значит
    /// проверять не то.
    public func deliver(_ cleaned: String, using delivery: TextDelivery) -> CleanupRetryOutcome {
        let wanted = delivered.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = delivery.fieldText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == wanted else {
            delivery.copy(cleaned)
            return .copied
        }
        if case .pasted = delivery.replace(cleaned) { return .replaced }
        // Замена не прошла (парольное поле, нет разрешения) — она в этом случае и в буфер
        // ничего не кладёт. Кладём сами: терять результат повтора нельзя.
        delivery.copy(cleaned)
        return .copied
    }
}

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

/// Сериализует распознавание: инстанс модели не потокобезопасен, а вызовы могут прийти
/// из разных задач. Актор реентерабелен (на `await` он освобождается), поэтому вызовы
/// выстроены в цепочку задач — как в `VadGate.feedStream`.
actor EngineGate {
    private let engine: TranscriptionEngine
    /// Хвост цепочки: только «дождаться предыдущего», без его результата.
    private var inFlight: Task<Void, Never>?

    init(_ engine: TranscriptionEngine) {
        self.engine = engine
    }

    /// Загрузка модели идёт мимо цепочки: она не трогает уже прогретый инстанс,
    /// а движок сам склеивает параллельные `prepare`.
    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        try await engine.prepare(language: language, onState: onState)
    }

    /// Проход распознавания. Сериализован: модель одна, и лезть в неё двумя задачами сразу
    /// нельзя — при наложении диктовок это происходило бы постоянно.
    func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool = false
    ) async throws -> String {
        let previous = inFlight
        let task = Task { [self] in
            _ = await previous?.value
            return try await engine.transcribe(
                samples, language: language, prompt: prompt, translating: translating
            )
        }
        // Регистрация синхронна: между чтением и записью `inFlight` нет ни одного await.
        // Ошибку цепочка глотает — она уже уехала тому, кто этот проход заказал.
        inFlight = Task { _ = try? await task.value }
        return try await task.value
    }
}


/// Слова в тексте. Раньше рядом жил гейт коротких диктовок — «на „ок“ чистка ничего
/// не меняет, а стоит целого круга к модели». С единственным Parakeet гейта не осталось:
/// английские названия он пишет кириллицей, латиницу им возвращает только чистка, и на
/// однословном «дэплой» её пропуск виден ярче всего. Поэтому через слой 3 идёт каждая
/// диктовка, а настройки, которая это отключала, больше нет.
enum ShortDictation {

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
    /// Промпт диктовки. Parakeet подсказку игнорирует (входа для неё у него нет), но поле
    /// живёт: словарь всё равно применяется вторым слоем, а протокол движка промпт принимает.
    var prompt = ""

    // MARK: Живёт, пока идёт запись

    /// Диктовку сняли ещё на записи (Esc, сбой захвата).
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

    /// Спросить человека, класть ли замеченную правку в словарь. Ответ приходит в замыкание:
    /// `true` — добавить, `false` — отказ навсегда. Не позвать ответ вовсе значит «человек
    /// не увидел вопроса»: тогда не происходит ничего и в следующий раз спросят снова.
    ///
    /// Не назначен — словарь не пополняется правками (так живёт CLI): спрашивать некого,
    /// а класть без спроса нельзя.
    public var onLearnRequest: ((LearnRequest, @escaping (Bool) -> Void) -> Void)?

    /// Чистка не удалась, а текст уже вставлен — предложить сделать её ещё раз.
    /// Не назначен — ничего не предлагаем (так живёт CLI): текст слоя 2 и так на месте.
    public var onCleanupFailed: ((CleanupRetry) -> Void)?

    /// Строка истории той диктовки, чистку которой предложено повторить: успешный повтор
    /// переписывает и её, иначе история осталась бы с нечищеным текстом навсегда.
    private var retryHistoryID: UUID?

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

    private var chunks: AsyncStream<[Float]>.Continuation?
    private var vadTask: Task<Void, Never>?
    /// Петля бегущей строки: живёт ровно столько же, сколько запись.
    private var livePreviewTask: Task<Void, Never>?
    /// Склейка проходов бегущей строки в одну растущую строку. Живёт ровно одну запись.
    private var livePreview = LiveTranscript()
    /// Наибольший пик, встречавшийся в окнах предпросмотра этой записи.
    ///
    /// Раньше каждое окно нормировалось по своему пику, и множитель плавал: громкое слово
    /// вошло в окно — и та же самая середина речи попадала в модель тише, чем в прошлый раз.
    /// Модель на этом слышит её иначе, и строка переписывалась сама собой там, где человек
    /// ничего нового не сказал. Накопленный пик назад не растёт: усиление перестаёт скакать
    /// и сходится к тому, с каким запись пойдёт финальным проходом.
    private var livePreviewPeak: Float = 0
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
        // Язык уже идущей записи от этого не меняется — см. `activeSessionLanguage`.
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
            prompt: ""
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
            mixesUkrainian: settings.mixesUkrainian
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

        // Промпт пуст: у распознавания нет входа для подсказки словарём — словарь
        // отрабатывает вторым слоем. Поле оставлено, потому что его принимает протокол.
        session.prompt = ""

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
        startLivePreview(language: session.language)
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


    private func append(_ chunk: [Float]) {
        guard isRecording else { return }
        chunks?.yield(chunk)
    }

    private func updateLevel(_ value: Float) {
        guard case .recording(let live, _) = recordingState else { return }
        recordingState = .recording(live: live, level: value)
        publish()
    }

    // MARK: - Бегущая строка

    /// Сколько секунд хвоста записи перечитываем ради бегущей строки.
    ///
    /// Именно хвоста, а не всей записи: работа тогда постоянна и не зависит от длины
    /// диктовки. Читать целиком означало бы, что на минутной речи проход занимает секунды
    /// и строка отстаёт тем сильнее, чем дольше говорят, — то есть ломается ровно там,
    /// где она нужнее. Бегущей строке дальнее прошлое и не нужно: оно уже уехало за край.
    ///
    /// Десять, а не пятнадцать. Контекст точности прибавляет, но платится за него не только
    /// временем прохода: чем реже приходят куски, тем они крупнее, а лента показывает окно
    /// шириной примерно в четыре слова. Кусок крупнее окна ей нечем «проехать» — она
    /// упирается в конец текста и встаёт до следующего прохода (замерено следом движения:
    /// четверть кадров простаивала). Десять секунд — проход около полусекунды, и куски
    /// выходят по два-три слова, то есть меньше окна.
    private static let livePreviewSeconds = 10.0

    /// Пауза между проходами.
    ///
    /// Было 900 мс, и вместе с самим проходом это давало кусок раз в полторы секунды —
    /// то есть четыре-пять слов разом при ширине окна в четыре. Лента такой кусок показать
    /// не успевала: она проезжала его быстрее, чем приходил следующий, и стояла остаток
    /// времени. 600 мс — куски по два-три слова, ход выходит непрерывным. Ниже опускаться
    /// нельзя: проход по десяти секундам занимает около полусекунды, и при 600 мс движок
    /// работал бы восемь десятых времени диктовки — это греет машину и отнимает у главного
    /// распознавания. 800 мс — куски по два слова и примерно шесть десятых занятости.
    private static let livePreviewPeriod = Duration.milliseconds(800)

    /// Раньше этого не начинаем: на полусекунде речи распознавание отдаёт обрывок слова,
    /// и строка дёргается больше, чем показывает.
    private static let livePreviewMinimumSeconds = 1.0

    /// Раньше этого числа слов строки нет вовсе — капсула держит волну.
    ///
    /// Дело не в красоте: на одном-двух словах якоря склейки (`LiveTranscript.anchorWords`)
    /// ещё не набралось, и каждый проход правит сам себя целиком. Четыре слова — первый
    /// момент, когда строка уже строка, а не мигающий обрывок.
    private static let livePreviewMinimumWords = 4

    /// Перечитывает хвост записи, пока она идёт, и складывает результат в капсулу.
    ///
    /// Стоит настоящих проходов распознавания, поэтому включается только выбором человека
    /// (`PillStyle.words`). Проход идёт через тот же `EngineGate`, что и настоящая диктовка:
    /// инстанс модели один. Отсюда же плата — стоп, пойманный ровно в момент идущего
    /// предпросмотра, ждёт его конца (доли секунды). Ради этого предпросмотр не запускается,
    /// когда очередь обработки не пуста: там чужой, уже сказанный текст, и он важнее.
    private func startLivePreview(language: Language) {
        // Новая запись — новая строка и новый пик: остаток прошлой диктовки в капсуле был бы
        // враньём, а её пик занижал бы усиление этой.
        livePreview = LiveTranscript()
        livePreviewPeak = 0
        guard settings.pillStyle == .words else { return }
        livePreviewTask = Task { [weak self] in
            var next = ContinuousClock.now
            while !Task.isCancelled {
                // Ждём до СЛЕДУЮЩЕГО срока, а не «столько-то после прошлого раза». Пауза
                // и сам проход складывались: при паузе 600 мс и проходе в полсекунды текст
                // приходил раз в 1,1 с, то есть кусками вдвое крупнее задуманного — а кусок
                // крупнее окна ленте нечем проехать, она упирается в конец текста и встаёт.
                next = next.advanced(by: Self.livePreviewPeriod)
                try? await Task.sleep(until: next)
                guard !Task.isCancelled, let self else { return }
                guard let tail = self.livePreviewTail() else { continue }
                guard let text = try? await self.gate.transcribe(
                    tail, language: language, prompt: ""
                ) else { continue }
                guard !Task.isCancelled else { return }
                self.showLive(text)
                // Отстали БОЛЬШЕ ЧЕМ НА ПЕРИОД — не копим долг, а берём новый отсчёт:
                // иначе после медленного прохода посыпалась бы очередь мгновенных.
                //
                // Сравнивать `next` с «сейчас» напрямую нельзя, и это была ровно та ошибка,
                // ради починки которой всё и затевалось: `next` — срок, на котором проход
                // НАЧАЛСЯ, значит после любого прохода ненулевой длительности он уже
                // в прошлом. Расписание переставлялось на «сейчас» каждый раз, и период
                // оставался прежним «пауза плюс проход».
                let overdue = ContinuousClock.now
                if next.advanced(by: Self.livePreviewPeriod) < overdue { next = overdue }
            }
        }
    }

    /// Хвост записи для предпросмотра — или nil, если читать нечего или сейчас не время.
    private func livePreviewTail() -> [Float]? {
        guard isRecording, pending.isEmpty else { return nil }
        let captured = recorder.capturedSamples
        guard captured.count >= AudioCaptureFormat.samples(seconds: Self.livePreviewMinimumSeconds) else {
            return nil
        }
        let window = AudioCaptureFormat.samples(seconds: Self.livePreviewSeconds)
        let tail = captured.count > window ? Array(captured.suffix(window)) : captured
        livePreviewPeak = max(livePreviewPeak, AudioNormalizer.peak(tail))
        return AudioNormalizer.scaled(tail, by: AudioNormalizer.gain(forPeak: livePreviewPeak))
    }

    /// Кладёт очередной проход в склейку и показывает то, что из неё вышло.
    ///
    /// Guard первым: проход мог доехать уже после Esc или стопа, и трогать склейку тогда
    /// нельзя вовсе — следующая запись начала бы с чужого хвоста.
    private func showLive(_ pass: String) {
        guard case .recording(let shown, let level) = recordingState else { return }
        livePreview.absorb(pass)
        guard livePreview.wordCount >= Self.livePreviewMinimumWords else { return }
        let text = livePreview.text
        // Проход не добавил ни слова (человек молчит) — публиковать нечего: лишний `publish`
        // перезапустил бы ход ленты на неизменившемся тексте.
        guard text != shown else { return }
        recordingState = .recording(live: text, level: level)
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
        livePreviewTask?.cancel()
        livePreviewTask = nil
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
        livePreviewTask?.cancel()
        livePreviewTask = nil
        // Отмена не прерывает идущий проход (он живёт своей задачей в `EngineGate`),
        // зато снимает передышку между проходами — иначе финал ждал бы её впустую.
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
        livePreviewTask?.cancel()
        livePreviewTask = nil
        // Идущий фоновый проход не прерывается: `EngineGate` отмену не смотрит, а WhisperKit
        // не умеет её вовсе — он досчитает в никуда, как и загрузка модели на отмене.
        // Флаг делает его результат заведомо мёртвым: `confirm` отбросит сегменты, даже
        // если они придут раньше, чем начнётся следующая запись.
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
        processingState = .transcribing
        publish()
        do {
            let entries = dictionary.entries
            // Решение о переводе принято на стопе — здесь его только исполняем.
            let wantsTranslation = session.translatesToEnglish
            // Распознавание одним проходом по обрезанной записи. Потокового пути больше
            // нет и не нужно: он существовал, потому что Whisper считала девятисекундную
            // запись четыре секунды, а Parakeet ту же — за десятые доли.
            let vad = try await ensureVad()
            guard let speech = try await vad.trimmed(leveled) else {
                throw DictationError.noSpeech
            }
            let raw = try await gate.transcribe(
                speech, language: language, prompt: session.prompt
            )
            var text = ReplacementEngine.apply(raw, entries: entries)
            var degradations: [String] = []
            var translation: String?
            var cleanupFailed = false

            // Через чистку идёт КАЖДАЯ диктовка: латиницу английским названиям возвращает
            // только она, и на однословном «дэплой» её пропуск виден ярче всего.
            if settings.gptEnabled {
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
                        mixesUkrainian: settings.mixesUkrainian
                    )
                    if wantsTranslation {
                        translation = processed
                    } else {
                        text = processed
                    }
                } catch {
                    // Слой 3 не обязателен: отдаём результат слоя 2 и говорим об этом.
                    // На переводе тем же вызовом теряется не чистка, а сам перевод — и в поле
                    // уедет русский текст. Сказать «без AI-чистки» там значило бы соврать
                    // о главном.
                    degradations.append(
                        wantsTranslation
                            ? "перевода нет: \(error.localizedDescription)"
                            : "без AI-чистки: \(error.localizedDescription)"
                    )
                    logger.error("GPT-слой не отработал: \(error.localizedDescription, privacy: .public)")
                    // Текст слоя 2 всё равно уедет в поле — терять его нельзя. Но чистку
                    // можно попробовать ещё раз: осечка тут почти всегда сетевая, и второй
                    // заход обычно проходит. Что именно предлагать, решаем после доставки:
                    // до неё неизвестно, попал ли текст в поле вообще.
                    cleanupFailed = true
                }
            } else if wantsTranslation {
                // Переводить больше нечем. Раньше запасным путём была сама модель
                // распознавания: Whisper умела отдавать английский задачей декодера.
                // Parakeet так не умеет — и делать вид, что перевод «просто не удался»,
                // нечестно: человек нажал правый ⌥ и обязан узнать, что именно включить.
                degradations.append("перевод делает ChatGPT — включите AI-чистку в настройках")
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
            let historyID = history.add(
                output, language: language, audio: saved?.name, seconds: saved?.seconds
            )
            // Словарь учится на правках человека, а не на догадках по виду слова. Если текст
            // действительно уехал в поле, берём это поле под наблюдение: что человек в нём
            // поправит, то и есть настоящая ошибка распознавания. В карточке и в буфере
            // обмена наблюдать нечего — там никто ничего не правит.
            // `text` здесь — то, что услышало распознавание (со словарём, но до GPT):
            // словарь применяется именно к нему, и учить надо его словами. При переводе
            // `output` — вовсе английский, и без этой строки пара получалась бы из чужого
            // языка.
            if case .pasteboard(.pasted) = destination, settings.learnsFromEdits {
                watchEdits(of: output, recognized: text)
            }

            if case .pasteboard(.clipboardOnly(let reason)) = destination {
                degradations.append(Self.clipboardMessage(reason))
            }
            // Повтор предлагаем только тогда, когда есть что чинить И куда положить
            // результат: в карточке и в буфере обмена заменять нечего.
            if cleanupFailed, case .pasteboard(.pasted) = destination {
                retryHistoryID = historyID
                onCleanupFailed?(
                    CleanupRetry(
                        text: text,
                        delivered: output,
                        language: language,
                        translating: wantsTranslation
                    )
                )
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
    private func watchEdits(of text: String, recognized: String) {
        watcher.watch(inserted: text, recognized: recognized) { [weak self] observation in
            Task { @MainActor in await self?.learn(observation) }
        }
    }

    /// Судьба того, что человек сделал с нашим текстом: спрашиваем GPT, есть ли там
    /// исправление ошибки распознавания.
    ///
    /// Приложение само решить не может. Отличить исправление нашего текста от начала
    /// собственной работы можно только по смыслу, поэтому наблюдение копит ВСЮ картину
    /// за окно — с временем каждого изменения, — а разбирается в ней один запрос.
    ///
    /// Судья не обязателен: GPT выключен или не ответил — возвращаемся к прежнему правилу
    /// с повторением. Молча класть в словарь непроверенное нельзя: лишняя пара портит ВСЕ
    /// будущие диктовки, а пропущенную человек добавит руками.
    private func learn(_ observation: FieldObservation) async {
        let candidates: [Correction]
        if settings.gptEnabled,
           let pairs = await DictionaryJudge.pairs(
               in: observation,
               language: settings.language,
               config: settings.gptConfig
           ) {
            candidates = pairs
        } else {
            logger.notice("Правки: судьи нет — идут прежним путём, через повторение")
            candidates = learner.observe(
                observation.corrections.map(\.correction),
                entries: dictionary.entries
            )
        }

        let known = DictionaryTokens.known(dictionary.entries)
        for correction in candidates {
            // Слово уже в словаре — замена и так произойдёт сама. Однажды отвергнутое
            // не переспрашиваем.
            guard !known.contains(correction.heard.lowercased()),
                  !learner.isRefused(correction) else { continue }
            ask(LearnRequest(correction: correction, edited: Self.edited(correction, in: observation)))
        }
    }

    /// Слово, которое человек видел на экране и правил своими руками, — если причёсывание
    /// подменило его и оно не совпадает с услышанным.
    ///
    /// Ищется сличением НАШИХ ДВУХ текстов: услышанного и вставленного. Оба у нас на руках,
    /// сопоставить их можно без модели и без разбора поля — и, что важнее, ответ есть всегда,
    /// а не только когда правка легла в поле удобно. Первым заходом здесь стоял поиск среди
    /// однословных замен поля, и он молчал ровно в том случае, ради которого всё затевалось:
    /// правка вместе с соседней печатью сливается в один блок, разбор не даёт ничего — и
    /// человеку показали бы одно лишь «клайв», которого он в глаза не видел.
    ///
    /// Требуем «одно слово на одно»: причёсывание, переписавшее полфразы, разбирать нечем,
    /// и молчание здесь честнее догадки.
    static func edited(_ correction: Correction, in observation: FieldObservation) -> String? {
        let tidied = EditDiff.changes(before: observation.recognized, after: observation.dictated)
            .first {
                $0.removed.count == 1 && $0.added.count == 1
                    && $0.removed[0].caseInsensitiveCompare(correction.heard) == .orderedSame
            }?
            .added[0]
        guard let tidied,
              tidied.caseInsensitiveCompare(correction.heard) != .orderedSame
        else { return nil }
        return tidied
    }

    /// Показать человеку пару и спросить, класть ли её в словарь.
    ///
    /// Словарь не пополняется молча. Пара применяется ко ВСЕМ будущим диктовкам, и её цена
    /// несимметрична: пропущенную человек добавит руками, а лишняя тихо портит каждую
    /// следующую фразу. Ни судья, ни тем более правило такой ответственности не тянут —
    /// последнее слово за человеком.
    ///
    /// Молчание — это «нет, но спросим ещё»: вопрос мог просто остаться незамеченным.
    /// Отказ — «нет навсегда»: он и запоминается.
    private func ask(_ request: LearnRequest) {
        let correction = request.correction
        logger.notice(
            """
            Правка \(correction.heard, privacy: .public) → \(correction.meant, privacy: .public) \
            (в тексте было \(request.edited ?? "то же самое", privacy: .public)): спрашиваем человека
            """
        )
        guard let onLearnRequest else { return }
        onLearnRequest(request) { [weak self] accepted in
            guard let self else { return }
            guard accepted else {
                learner.ignore(correction)
                logger.notice("Правка отклонена человеком — больше не предлагаем")
                return
            }
            apply([learner.accept(correction, entries: dictionary.entries)])
        }
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
                // Наверх, а не в конец: порядок файла — это и есть порядок новизны, по нему
                // редактор показывает «сначала новые». Дописанное в конец слово оказывалось
                // в самом низу списка — то есть именно там, где его никто не ищет.
                entries.insert(entry, at: 0)
            }
        }
        dictionary.replace(entries: entries)
        for entry in learned {
            logger.notice("словарь пополнен правкой: \(entry.canonical, privacy: .public)")
        }
    }

    /// Повторить чистку, которая не удалась. Текст слоя 2 к этому моменту уже в поле —
    /// повтор либо заменяет его на чистый, либо (если поле стало чужим) кладёт результат
    /// в буфер обмена.
    ///
    /// Заменять вслепую нельзя: Cmd-A выделяет ВСЁ поле, и если человек успел дописать своё
    /// или ушёл в другое окно, замена затрёт чужое. Поэтому поле перечитывается прямо перед
    /// заменой и должно содержать ровно то, что мы вставили.
    @discardableResult
    public func retryCleanup(_ retry: CleanupRetry) async -> CleanupRetryOutcome {
        let entries = dictionary.entries
        let cleaned: String
        do {
            cleaned = try await PostProcessor.cleanup(
                text: retry.text,
                entries: entries,
                language: retry.language,
                config: retry.translating ? settings.translateGPTConfig : settings.gptConfig,
                translateToEnglish: retry.translating,
                mixesUkrainian: settings.mixesUkrainian
            )
        } catch {
            logger.error("Повтор чистки не удался: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }

        lastOriginal = retry.translating ? lastOriginal : cleaned
        if retry.translating { lastTranslation = cleaned }
        if let retryHistoryID {
            history.replace(id: retryHistoryID, text: cleaned)
            self.retryHistoryID = nil
        }

        // Опрос AX и синтетические клавиши блокируют поток — главный на это не занимаем.
        let delivery = self.delivery
        let outcome = await Task.detached(priority: .userInitiated) {
            retry.deliver(cleaned, using: delivery)
        }.value
        logger.notice("Повтор чистки: \(String(describing: outcome), privacy: .public)")
        return outcome
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
    ///
    /// Выбирать модель на повторе больше не из чего — она одна. Смысл повтора от этого
    /// не пропал: в первый раз запись могла обрезаться воротами речи или уехать в ошибку,
    /// а здесь она отдаётся модели целиком, вместе с тишиной.
    public func retranscribe(item: HistoryItem) async throws -> String {
        guard let audio = item.audio else { throw RecordingStoreError.missing }
        let samples = try recordings.samples(named: audio)
        let language = item.language

        processingState = .transcribing
        publish()
        defer {
            processingState = nil
            publish()
            scheduleIdle(after: Self.insertedLinger)
        }

        try await gate.prepare(language: language) { [weak self] modelState in
            Task { @MainActor in self?.apply(modelState) }
        }
        // Ворота речи не зовём вовсе: на повторе честнее отдать модели всё, включая тишину,
        // чем во второй раз недосчитаться. Уровень поднимаем — это ровно то, чего тихой
        // записи не хватало в первый раз.
        let raw = try await gate.transcribe(
            AudioNormalizer.normalized(samples),
            language: language,
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
