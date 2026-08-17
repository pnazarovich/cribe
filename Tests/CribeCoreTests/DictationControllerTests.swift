import XCTest
@testable import CribeCore

/// Движок-заглушка: `prepare` сообщает о загрузке и висит, пока тест его не отпустит —
/// как первая загрузка WhisperKit, которая специализируется под ANE минутами.
/// Фоновый проход по растущему буферу держится отдельным замком: так Esc попадает ровно
/// в окно «проход уже считает».
private final class GatedEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var passStartedFlag = false
    private var passReleased = false
    private var passContinuation: CheckedContinuation<Void, Never>?

    /// Сегменты, которые отдаст фоновый проход. Пустой массив — движок сегментов не умеет
    /// (как и по умолчанию в протоколе), и потокового пути в сессии не будет вовсе.
    private let segments: [ASRSegment]

    init(segments: [ASRSegment] = []) {
        self.segments = segments
    }

    /// Фоновый проход дошёл до движка.
    var passStarted: Bool { lock.withLock { passStartedFlag } }
    /// Проход начался и всё ещё считает.
    var passRunning: Bool { lock.withLock { passStartedFlag && !passReleased } }

    /// Отпускает загрузку: `prepare` доходит до конца, как и в жизни (прервать его нечем).
    func release() { lock.withLock { released = true } }

    /// Отпускает фоновый проход — он досчитывает и отдаёт сегменты.
    func releasePass() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            passReleased = true
            defer { passContinuation = nil }
            return passContinuation
        }
        continuation?.resume()
    }

    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        onState(.loading)
        while !lock.withLock({ released }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        onState(.ready)
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        XCTFail("отменённая сессия не должна доходить до распознавания")
        return ""
    }

    func transcribeSegments(_ samples: [Float], language: Language, prompt: String) async throws -> [ASRSegment] {
        guard !segments.isEmpty else { throw TranscriptionEngineError.segmentsUnsupported }
        lock.withLock { passStartedFlag = true }
        // Ждём через продолжение, а не `Task.sleep`: отмену задачи живой WhisperKit
        // не смотрит, и проход обязан досчитать вопреки `rollingTask.cancel()`.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyReleased = lock.withLock { () -> Bool in
                if passReleased { return true }
                passContinuation = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
        return segments
    }
}

/// Движок, который запоминает промпт распознавания и сразу отдаёт текст.
private final class PromptSpyEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: String?

    /// Промпт первого прохода; nil — распознавание ещё не начиналось.
    var prompt: String? { lock.withLock { seen } }

    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        onState(.ready)
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        lock.withLock { if seen == nil { seen = prompt } }
        return "текст"
    }
}

/// VAD-заглушка: настоящий гейт поднимает CoreML-модель и на чистой машине тянет её из сети,
/// а конвейеру от него нужен только вердикт. Здесь он всегда «речь есть, обрезать нечего»,
/// поэтому прогон обходится без модели и без единого сетевого запроса.
private final class PassThroughVad: SpeechGating, @unchecked Sendable {
    func trimmed(_ samples: [Float]) async throws -> [Float]? { samples.isEmpty ? nil : samples }
    func resetStream() async {}
    func feedStream(_ chunk: [Float]) async throws -> Bool { false }
}

/// Движок, который держит распознавание, пока тест его не отпустит: так Esc успевает
/// нажаться ровно на `.transcribing`, как и в жизни.
private final class HoldingEngine: TranscriptionEngine, @unchecked Sendable {
    static let text = "распознанный текст"

    private let lock = NSLock()
    private var released = false
    private var calls = 0

    /// Распознавание началось и ждёт `release()`.
    var isTranscribing: Bool { lock.withLock { calls > 0 } }

    func release() { lock.withLock { released = true } }

    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        onState(.ready)
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        lock.withLock { calls += 1 }
        // Прервать идущий проход нечем — он досчитывает и на отменённой сессии.
        while !lock.withLock({ released }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return Self.text
    }
}

/// Движок с распознаванием разной длительности: сколько считается каждый проход и что он
/// отдаёт, задаёт тест. Нужен там, где проверяется ПОРЯДОК: если первая диктовка считается
/// долго, а вторая мгновенно, совпадение порядка вставки с порядком речи перестаёт быть
/// случайностью таймингов.
private final class PacedEngine: TranscriptionEngine, @unchecked Sendable {
    private let passes: [(text: String, delay: TimeInterval)]
    private let lock = NSLock()
    private var callCount = 0

    init(passes: [(text: String, delay: TimeInterval)]) {
        self.passes = passes
    }

    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        onState(.ready)
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        let index = lock.withLock { () -> Int in
            defer { callCount += 1 }
            return callCount
        }
        guard index < passes.count else {
            XCTFail("проходов больше, чем задано тестом")
            return ""
        }
        let pass = passes[index]
        if pass.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(pass.delay * 1_000_000_000))
        }
        return pass.text
    }
}

/// Приёмник записок: замыкание живёт дольше вызова, поэтому поводы копим в объекте.
private final class NoticeSink {
    var notices: [DictationNotice] = []

    var hints: Int { notices.filter { $0 == .parallelHint }.count }
    var refusals: Int { notices.filter { $0 == .queueFull(limit: DictationController.maxPending) }.count }
}

/// Доставка-заглушка: считает вставки и копирования, но ни разу не трогает ни буфер обмена
/// пользователя, ни чужие окна. Вердикт детектора задаётся тестом.
private final class SpyDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var insertedTexts: [String] = []
    private var copiedTexts: [String] = []
    private var replacedTexts: [String] = []
    private var field: String?
    private let focus: FocusState

    init(focus: FocusState) {
        self.focus = focus
    }

    var inserted: [String] { lock.withLock { insertedTexts } }
    var copied: [String] { lock.withLock { copiedTexts } }
    var replaced: [String] { lock.withLock { replacedTexts } }

    /// Что «лежит в поле ввода» с точки зрения повторной чистки.
    func setField(_ text: String?) { lock.withLock { field = text } }

    var delivery: TextDelivery {
        TextDelivery(
            focus: { FocusVerdict(state: self.focus, role: nil) },
            insert: { text in
                self.lock.withLock { self.insertedTexts.append(text) }
                return .pasted
            },
            copy: { text in self.lock.withLock { self.copiedTexts.append(text) } },
            replace: { text in
                self.lock.withLock { self.replacedTexts.append(text) }
                return .pasted
            },
            fieldText: { self.lock.withLock { self.field } }
        )
    }
}

/// Приёмник карточек: замыкание живёт дольше вызова, поэтому текст копим в объекте.
/// `accepts` изображает стопку, которой некуда встать (не нашла экрана).
private final class CardSink {
    var texts: [String] = []
    var accepts = true
}

/// Захват-заглушка: живой микрофон в тестах не поднимаем, а конвейеру от захвата нужен
/// только сам факт вызовов. Заодно видно, доезжает ли выбор устройства из настроек.
private final class StubRecorder: AudioCapturing, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    /// UID последнего `setInputDevice`; двойная опциональность отличает «не вызывали» от «nil».
    private(set) var appliedUID: String??

    var capturedSamples: [Float] = []
    var capturedSilence = false
    var capturedSampleCount: Int { capturedSamples.count }

    func setInputDevice(uid: String?) { appliedUID = .some(uid) }
    func prepare() {}
    func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws {}
    func stop() -> [Float] { capturedSamples }
    func teardown() {}
}

@MainActor
final class DictationControllerTests: XCTestCase {
    private var dictionaryURL: URL!
    private var dir: URL!
    private var suiteName: String!
    /// Записи диктовок — во временную папку: прогон не имеет права класть звук
    /// в Application Support пользователя.
    private var recordings: RecordingStore!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DictationControllerTests-\(UUID().uuidString)")
        dictionaryURL = dir.appendingPathComponent("dictionary.json")
        suiteName = "DictationControllerTests-\(UUID().uuidString)"
        recordings = RecordingStore(folder: dir.appendingPathComponent("recordings"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Хоткей на загрузке модели отменяет сессию: записи не будет (микрофон так и не включится),
    /// состояние тихо возвращается в простой. Сама загрузка при этом доживает до конца.
    func testHotkeyDuringModelLoadCancelsSession() async throws {
        let engine = GatedEngine()
        let controller = makeController(engine: engine)

        controller.toggle()
        try await wait(for: "загрузку модели") {
            if case .preparingModel = controller.state { return true }
            return false
        }
        XCTAssertEqual(controller.activeSessionLanguage, .ru)

        controller.toggle()  // второй хоткей — отмена
        engine.release()

        try await wait(for: "выход из загрузки") {
            if case .preparingModel = controller.state { return false }
            return true
        }
        // Именно `.idle`: старт записи (или ошибка вместо него) означал бы, что отмена не сработала.
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeSessionLanguage)
    }

    /// Правый ⌥ назначает переводом всю сессию: флаг сессии встаёт сразу на старте,
    /// ещё до записи, и не зависит от выключенного тумблера настроек.
    func testTranslateHotkeyMarksSession() async throws {
        let engine = GatedEngine()
        let controller = makeController(engine: engine)

        controller.toggle(translating: true)
        try await wait(for: "загрузку модели") {
            if case .preparingModel = controller.state { return true }
            return false
        }
        XCTAssertEqual(controller.activeSessionTranslate, true)

        controller.toggle()  // второй хоткей — отмена
        engine.release()
        try await wait(for: "выход из загрузки") {
            if case .preparingModel = controller.state { return false }
            return true
        }
        // Флаг живёт ровно столько же, сколько язык сессии: следующая диктовка должна
        // снова решать сама, а не наследовать перевод от отменённой.
        XCTAssertNil(controller.activeSessionTranslate)
    }

    /// Обычная диктовка переопределения не ставит: решает `settings.translateToEnglish`,
    /// причём на момент конвейера — тумблер меню работает и на живой записи.
    func testPlainHotkeyLeavesTranslationToSettings() async throws {
        let engine = GatedEngine()
        let controller = makeController(engine: engine)

        controller.toggle()
        try await wait(for: "загрузку модели") {
            if case .preparingModel = controller.state { return true }
            return false
        }
        XCTAssertNil(controller.activeSessionTranslate)

        controller.toggle()
        engine.release()
        try await wait(for: "выход из загрузки") {
            if case .preparingModel = controller.state { return false }
            return true
        }
    }

    /// Остановка (здесь — отмена на загрузке модели) игнорирует `translating`: любой из двух
    /// хоткеев снимает чужую сессию, а не превращает её в переводящую и не запускает вторую.
    func testTranslateHotkeyStopsPlainSessionWithoutMarkingIt() async throws {
        let engine = GatedEngine()
        let controller = makeController(engine: engine)

        controller.toggle()
        try await wait(for: "загрузку модели") {
            if case .preparingModel = controller.state { return true }
            return false
        }

        controller.toggle(translating: true)  // второй хоткей — отмена, а не «переводить»
        engine.release()
        try await wait(for: "выход из загрузки") {
            if case .preparingModel = controller.state { return false }
            return true
        }
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeSessionTranslate)
    }

    /// До распознавания доезжает русский промпт русской сессии — ни одного украинского слова
    /// в нём быть не может. Раньше сюда добавлялся образец смешанной речи с украинской
    /// вставкой, и на настоящей диктовке он переворачивал язык всей записи.
    func testRussianSessionPromptStaysRussian() async throws {
        let ukrainianOnly: Set<Character> = ["і", "І", "ї", "Ї", "є", "Є", "ґ", "Ґ"]
        let prompt = try await sessionPrompt()

        XCTAssertFalse(prompt.isEmpty)
        XCTAssertFalse(prompt.contains(where: { ukrainianOnly.contains($0) }), prompt)
    }

    /// Хоткей смены языка гоняет языки по кругу в порядке `Language.allCases`. С тремя языками
    /// это единственное, что делает его предсказуемым: третий язык не имеет права превращать
    /// шорткат в тумблер, который «иногда попадает».
    func testSwitchLanguageCyclesThroughEveryLanguage() {
        let settings = makeSettings()
        settings.language = .ru
        let controller = DictationController(
            engine: GatedEngine(),
            dictionary: UserDictionary(url: dictionaryURL),
            settings: settings,
            recorder: StubRecorder()
        )

        var seen: [Language] = []
        for _ in Language.allCases {
            controller.switchLanguage()
            seen.append(settings.language)
        }

        XCTAssertEqual(seen, [.uk, .en, .ru], "круг обязан пройти все языки и вернуться в начало")
        XCTAssertEqual(Set(seen), Set(Language.allCases))
    }

    /// Промпт, с которым сессия дошла до распознавания.
    private func sessionPrompt() async throws -> String {
        let engine = PromptSpyEngine()
        let settings = makeSettings()
        let controller = DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dictionaryURL),
            settings: settings,
            recorder: recordedThreeSeconds(),
            delivery: SpyDelivery(focus: .unknown).delivery,
            makeVad: { PassThroughVad() },
            recordings: recordings
        )

        controller.toggle()
        try await wait(for: "старт записи") {
            if case .recording = controller.state { return true }
            return false
        }
        controller.toggle()
        try await wait(for: "распознавание") { engine.prompt != nil }
        return engine.prompt ?? ""
    }

    /// Выбор микрофона из меню доезжает до захвата: пункт пишет UID в настройки, а подписка
    /// контроллера отдаёт его записи. Стартовое значение применяется прямо в `init`.
    func testInputDeviceSelectionReachesRecorder() async throws {
        let recorder = StubRecorder()
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        let controller = DictationController(
            engine: GatedEngine(),
            dictionary: UserDictionary(url: dictionaryURL),
            settings: settings,
            recorder: recorder,
            recordings: recordings
        )
        XCTAssertEqual(recorder.appliedUID, .some(nil))

        settings.inputDeviceUID = "TestMicrophoneUID"
        try await wait(for: "передачу UID в захват") {
            recorder.appliedUID == .some("TestMicrophoneUID")
        }
        withExtendedLifetime(controller) {}
    }

    /// Цифровая тишина на входе — это не «речь не обнаружена»: на такой записи молчал
    /// микрофон, и сообщение должно говорить про вход, а не про пользователя.
    func testSilentInputRewritesNoSpeechMessage() throws {
        let recorder = StubRecorder()
        recorder.capturedSilence = true
        let controller = makeController(engine: GatedEngine(), recorder: recorder)

        XCTAssertEqual(
            controller.message(for: DictationError.noSpeech),
            "микрофон молчит — выберите другой вход в меню «Микрофон»"
        )
        // Живой вход оставляет исходное сообщение — подмена не должна врать в обратную сторону.
        recorder.capturedSilence = false
        XCTAssertEqual(
            controller.message(for: DictationError.noSpeech),
            DictationError.noSpeech.localizedDescription
        )
        // Чужие ошибки не трогаем даже на тишине.
        recorder.capturedSilence = true
        let other = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "что-то своё"])
        XCTAssertEqual(controller.message(for: other), "что-то своё")
    }

    // MARK: - Отмена по Esc

    /// Esc на живой записи выбрасывает записанное целиком: до движка оно не доезжает,
    /// «последняя диктовка» не меняется, а панель показывает отмену и гаснет сама.
    func testEscapeDuringRecordingDiscardsBuffer() async throws {
        let recorder = StubRecorder()
        // Буфер непустой: цена отмены — именно выброшенная запись, а не пустое место.
        recorder.capturedSamples = [Float](repeating: 0.1, count: AudioCaptureFormat.samples(seconds: 3))
        // `GatedEngine.transcribe` роняет тест сам: отменённая запись до распознавания
        // не должна доходить ни одним путём.
        let engine = GatedEngine()
        let controller = makeController(engine: engine, recorder: recorder)

        controller.toggle()
        engine.release()
        try await wait(for: "старт записи") {
            if case .recording = controller.state { return true }
            return false
        }

        controller.cancelDictation()
        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertNil(controller.lastOriginal)

        // Вспышка гаснет сама — без ошибки и без второй сессии.
        try await wait(for: "возврат в простой") { controller.state == .idle }
        XCTAssertNil(controller.lastOriginal)
        XCTAssertNil(controller.activeSessionLanguage)
    }

    /// Esc на длинной записи, когда фоновый проход уже считает: прервать проход нечем,
    /// но отмена его не ждёт, а досчитанные сегменты уже мертвы — поколение сессии сдвинуто.
    func testEscapeDuringRecordingKillsInFlightStreamingPass() async throws {
        let recorder = StubRecorder()
        // Длиннее порога потокового пути (6 с) — короче фоновых проходов не бывает вовсе.
        recorder.capturedSamples = [Float](repeating: 0.1, count: AudioCaptureFormat.samples(seconds: 8))
        // Два сегмента: первый устоявшийся, второй проход обычно переписывает — значит,
        // подтвердить есть что, и молчание `confirm` не может быть случайным.
        let engine = GatedEngine(segments: [
            ASRSegment(text: "первый кусок", start: 0, end: 3),
            ASRSegment(text: "второй кусок", start: 3, end: 6),
        ])
        let controller = makeController(engine: engine, recorder: recorder)

        controller.toggle()
        engine.release()
        try await wait(for: "старт записи") {
            if case .recording = controller.state { return true }
            return false
        }
        try await wait(for: "старт фонового прохода") { engine.passStarted }

        controller.cancelDictation()
        // Отмена мгновенная: проход ещё считает, а сессии уже нет.
        XCTAssertEqual(controller.state, .cancelled)
        XCTAssertTrue(engine.passRunning)

        engine.releasePass()
        try await wait(for: "возврат в простой") { controller.state == .idle }
        // Проход досчитал уже после отмены — подтверждать ему нечего.
        XCTAssertEqual(controller.confirmedText, "")
        XCTAssertEqual(controller.confirmedEndSample, 0)
    }

    /// Esc на загрузке модели отменяет сессию так же, как второй хоткей, но мигает
    /// «Отменено»: без вспышки непонятно, дошло нажатие или загрузка просто идёт дальше.
    func testEscapeDuringModelLoadFlashesCancel() async throws {
        let engine = GatedEngine()
        let controller = makeController(engine: engine)

        controller.toggle()
        try await wait(for: "загрузку модели") {
            if case .preparingModel = controller.state { return true }
            return false
        }

        controller.cancelDictation()
        engine.release()
        try await wait(for: "вспышку отмены") { controller.state == .cancelled }
        try await wait(for: "возврат в простой") { controller.state == .idle }
        XCTAssertNil(controller.activeSessionLanguage)
    }

    /// Esc, нажатый пока конвейер уже считает, диктовку НЕ отменяет: записанное почти
    /// доехало, и выбросить готовую работу обиднее, чем недоотменить. Клавиша принадлежит
    /// живой записи, а её в этот момент нет — значит, отменять нечего.
    func testEscapeDuringProcessingKeepsResult() async throws {
        let spy = SpyDelivery(focus: .unknown)
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)

        controller.toggle()
        try await wait(for: "старт записи") {
            if case .recording = controller.state { return true }
            return false
        }

        controller.toggle()  // стоп — дальше работает очередь
        XCTAssertEqual(controller.state, .transcribing)
        controller.cancelDictation()
        // Отмены не случилось: конвейер как считал, так и считает.
        XCTAssertEqual(controller.state, .transcribing)
        XCTAssertEqual(controller.pendingCount, 1)

        // Движок держит проход до этого момента, поэтому Esc гарантированно раньше вставки.
        try await wait(for: "начало распознавания") { engine.isTranscribing }
        engine.release()

        try await wait(for: "вставку") { controller.state == .inserted }
        XCTAssertEqual(spy.inserted, [HoldingEngine.text])
        XCTAssertEqual(controller.lastOriginal, HoldingEngine.text)
    }

    // MARK: - Наложение: пишем новое, пока доезжает старое

    /// Главное требование наложения: диктовки вставляются строго в том порядке, в котором
    /// их наговорили. Первая здесь распознаётся втрое дольше второй — если бы очередь
    /// разбиралась «кто быстрее», предложения поменялись бы местами.
    func testQueuedDictationsInsertInSpokenOrder() async throws {
        let spy = SpyDelivery(focus: .unknown)
        let engine = PacedEngine(passes: [
            (text: "первая фраза", delay: 0.3),
            (text: "вторая фраза", delay: 0),
        ])
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)

        controller.toggle()
        try await wait(for: "старт первой записи") {
            if case .recording = controller.state { return true }
            return false
        }
        controller.toggle()  // стоп первой — она уходит в очередь

        // Вторая запись начинается, не дожидаясь первой: ровно то, ради чего всё затевалось.
        controller.toggle()
        try await wait(for: "старт второй записи") {
            if case .recording = controller.state { return true }
            return false
        }
        XCTAssertEqual(controller.pendingCount, 1, "первая обязана обрабатываться параллельно записи")
        controller.toggle()

        try await wait(for: "обе вставки") { spy.inserted.count == 2 }
        XCTAssertEqual(spy.inserted, ["первая фраза", "вторая фраза"])
        try await wait(for: "опустевшую очередь") { controller.pendingCount == 0 }
    }

    /// Потолок очереди. Четвёртая диктовка не начинается — и отказ не молчаливый: наружу
    /// уходит записка, по которой видно, почему микрофон не включился.
    func testFourthDictationIsRefusedWhileThreeArePending() async throws {
        let sink = NoticeSink()
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds())
        controller.onNotice = { sink.notices.append($0) }

        for index in 1...DictationController.maxPending {
            controller.toggle()
            try await wait(for: "старт записи \(index)") {
                if case .recording = controller.state { return true }
                return false
            }
            controller.toggle()
        }
        try await wait(for: "полную очередь") {
            controller.pendingCount == DictationController.maxPending
        }

        controller.toggle()  // четвёртая — некуда
        XCTAssertEqual(sink.refusals, 1, "отказ обязан быть слышен")
        XCTAssertEqual(controller.pendingCount, DictationController.maxPending)
        XCTAssertEqual(controller.state, .transcribing, "записи не начиналось")

        // Как только очередь разгребается, хоткей снова работает.
        engine.release()
        try await wait(for: "разбор очереди") { controller.pendingCount == 0 }
        controller.toggle()
        try await wait(for: "старт четвёртой записи") {
            if case .recording = controller.state { return true }
            return false
        }
        controller.cancelDictation()
    }

    /// Esc при наложении снимает ТОЛЬКО идущую запись. Диктовка, которая в этот момент
    /// обрабатывается, доезжает до поля ввода как ни в чём не бывало.
    func testEscapeDuringOverlapCancelsOnlyLiveRecording() async throws {
        let spy = SpyDelivery(focus: .unknown)
        let sink = NoticeSink()
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)
        controller.onNotice = { sink.notices.append($0) }

        controller.toggle()
        try await wait(for: "старт первой записи") {
            if case .recording = controller.state { return true }
            return false
        }
        controller.toggle()  // стоп первой — она встала в очередь и считается

        controller.toggle()
        try await wait(for: "старт второй записи") {
            if case .recording = controller.state { return true }
            return false
        }
        controller.cancelDictation()

        // Первая на месте, второй больше нет.
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertEqual(controller.state, .transcribing)
        // Пилюлю занял конвейер, поэтому про отмену сказала записка — молчать здесь нельзя.
        XCTAssertEqual(sink.notices, [.result(.cancelled)])

        engine.release()
        try await wait(for: "вставку первой") { controller.state == .inserted }
        XCTAssertEqual(spy.inserted, [HoldingEngine.text], "отменённая запись до движка не дошла")
    }

    /// Подсказка про наложение показывается ровно один раз за всю жизнь приложения —
    /// на третьей диктовке — и переживает перезапуск: флаг лежит в настройках.
    func testParallelHintShowsOnceOnThirdDictation() async throws {
        let sink = NoticeSink()
        let settings = makeSettings()
        let engine = HoldingEngine()
        engine.release()  // распознавание не держим: интересна только подсказка
        let controller = makeController(
            engine: engine,
            recorder: recordedThreeSeconds(),
            settings: settings
        )
        controller.onNotice = { sink.notices.append($0) }

        for index in 1...4 {
            controller.toggle()
            try await wait(for: "старт записи \(index)") {
                if case .recording = controller.state { return true }
                return false
            }
            controller.toggle()
            try await wait(for: "разбор очереди после записи \(index)") { controller.pendingCount == 0 }

            // До третьей молчим, с третьей — ровно одна подсказка и больше никогда.
            XCTAssertEqual(sink.hints, index < 3 ? 0 : 1, "после \(index)-й диктовки")
        }
        XCTAssertTrue(settings.parallelHintShown)

        // Новый контроллер на тех же настройках — это и есть перезапуск приложения.
        let second = makeController(engine: engine, recorder: recordedThreeSeconds(), settings: settings)
        second.onNotice = { sink.notices.append($0) }
        second.toggle()
        try await wait(for: "старт записи после перезапуска") {
            if case .recording = second.state { return true }
            return false
        }
        second.cancelDictation()
        XCTAssertEqual(sink.hints, 1, "подсказка одна на всю жизнь приложения")
    }

    /// Esc вне сессии — ничего: панель не мигает отменой там, где отменять нечего.
    func testEscapeWhileIdleDoesNothing() throws {
        let controller = makeController(engine: GatedEngine())
        XCTAssertEqual(controller.state, .idle)
        controller.cancelDictation()
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - Карточки вместо вставки вслепую

    /// Поля ввода нет: текст уходит карточкой, а не Cmd-V вслепую. В буфере обмена он при
    /// этом остаётся — контракт прежний, карточку можно и не трогать.
    func testNoFocusedFieldRoutesTextToCard() async throws {
        let spy = SpyDelivery(focus: .notEditable)
        let sink = CardSink()
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)
        controller.onCardText = { sink.texts.append($0); return sink.accepts }

        try await runDictation(controller: controller, engine: engine)
        try await wait(for: "карточку") { controller.state == .carded }

        XCTAssertEqual(sink.texts, [HoldingEngine.text])
        XCTAssertTrue(spy.inserted.isEmpty, "вставки быть не должно — вставлять некуда")
        XCTAssertEqual(spy.copied, [HoldingEngine.text])
        // Карточка истории не отменяет: вытесненную из стопки диктовку надо где-то найти.
        // Сравниваем верхнюю запись, а не длину: история упирается в свой потолок.
        XCTAssertEqual(HistoryStore.shared.items.first?.text, HoldingEngine.text)
        XCTAssertEqual(controller.lastOriginal, HoldingEngine.text)
    }

    /// Детектор не уверен (нет разрешения, приложение молчит) — всё как раньше: Cmd-V.
    /// Это главное правило: сомнение трактуется в пользу вставки.
    func testUnknownFocusKeepsNormalInsert() async throws {
        let spy = SpyDelivery(focus: .unknown)
        let sink = CardSink()
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)
        controller.onCardText = { sink.texts.append($0); return sink.accepts }

        try await runDictation(controller: controller, engine: engine)
        try await wait(for: "вставку") { controller.state == .inserted }

        XCTAssertEqual(spy.inserted, [HoldingEngine.text])
        XCTAssertTrue(sink.texts.isEmpty, "карточка не для неуверенного вердикта")
    }

    /// Выключённая настройка отменяет карточки целиком: детектор даже не спрашивается,
    /// вставка идёт вслепую, как до этой функции.
    func testDisabledSettingKeepsNormalInsert() async throws {
        let spy = SpyDelivery(focus: .notEditable)
        let sink = CardSink()
        let engine = HoldingEngine()
        let controller = makeController(
            engine: engine,
            recorder: recordedThreeSeconds(),
            delivery: spy,
            cardsWhenNoField: false
        )
        controller.onCardText = { sink.texts.append($0); return sink.accepts }

        try await runDictation(controller: controller, engine: engine)
        try await wait(for: "вставку") { controller.state == .inserted }

        XCTAssertEqual(spy.inserted, [HoldingEngine.text])
        XCTAssertTrue(sink.texts.isEmpty)
    }

    /// Стопки карточек нет вовсе (так живёт CLI) — конвейер обязан вставлять, а не терять текст.
    func testMissingCardSinkKeepsNormalInsert() async throws {
        let spy = SpyDelivery(focus: .notEditable)
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)

        try await runDictation(controller: controller, engine: engine)
        try await wait(for: "вставку") { controller.state == .inserted }

        XCTAssertEqual(spy.inserted, [HoldingEngine.text])
    }

    /// Поле ввода есть — карточку не трогаем вовсе: обычная вставка, как до этой функции.
    func testEditableFieldRoutesToInsert() async throws {
        let spy = SpyDelivery(focus: .editable)
        let sink = CardSink()
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)
        controller.onCardText = { sink.texts.append($0); return sink.accepts }

        try await runDictation(controller: controller, engine: engine)
        try await wait(for: "вставку") { controller.state == .inserted }

        XCTAssertEqual(spy.inserted, [HoldingEngine.text])
        XCTAssertTrue(sink.texts.isEmpty)
    }

    /// Стопка карточку не приняла (не нашла экрана): текст обязан уехать обычной вставкой.
    /// Иначе состояние сказало бы «в карточку», а карточки бы не было — диктовка пропала.
    func testRefusedCardFallsBackToInsert() async throws {
        let spy = SpyDelivery(focus: .notEditable)
        let sink = CardSink()
        sink.accepts = false
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recordedThreeSeconds(), delivery: spy)
        controller.onCardText = { sink.texts.append($0); return sink.accepts }

        try await runDictation(controller: controller, engine: engine)
        try await wait(for: "вставку") { controller.state == .inserted }

        XCTAssertEqual(sink.texts, [HoldingEngine.text], "стопку всё-таки спросили")
        XCTAssertEqual(spy.inserted, [HoldingEngine.text], "и вставили, раз она отказала")
    }

    // MARK: - Обвязка

    /// Полный круг диктовки: старт, стоп, отпущенный движок. Дальше остаётся дождаться
    /// терминального состояния — оно и есть предмет проверки.
    private func runDictation(controller: DictationController, engine: HoldingEngine) async throws {
        controller.toggle()
        try await wait(for: "старт записи") {
            if case .recording = controller.state { return true }
            return false
        }
        controller.toggle()
        engine.release()
    }

    private func recordedThreeSeconds() -> StubRecorder {
        let recorder = StubRecorder()
        recorder.capturedSamples = [Float](repeating: 0.1, count: AudioCaptureFormat.samples(seconds: 3))
        return recorder
    }

    private func makeController(
        engine: TranscriptionEngine,
        recorder: AudioCapturing = StubRecorder(),
        // По умолчанию — вердикт «не знаю»: ни один прогон не имеет права уехать в живую
        // систему, даже если тест доберётся до последнего шага конвейера случайно.
        delivery: SpyDelivery = SpyDelivery(focus: .unknown),
        cardsWhenNoField: Bool = true,
        // Свои настройки нужны там, где проверяется то, что в них и живёт (разовая
        // подсказка): один и тот же объект переживает пересоздание контроллера.
        settings: AppSettings? = nil
    ) -> DictationController {
        let settings = settings ?? makeSettings()
        settings.cardsWhenNoField = cardsWhenNoField
        return DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dictionaryURL),
            settings: settings,
            recorder: recorder,
            delivery: delivery.delivery,
            // Заглушка вместо Silero: прогон не поднимает CoreML-модель и не ходит за ней в сеть.
            makeVad: { PassThroughVad() },
            recordings: recordings
        )
    }

    private func makeSettings() -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        // Тесты доходят до живой записи, а прогон звенеть чаймами не должен.
        settings.soundsEnabled = false
        // И не должен ходить в сеть: с включённым слоем 3 старт записи шлёт прогревочный
        // запрос к GPT (`prewarmGPT`), а конвейер — саму чистку.
        settings.gptEnabled = false
        return settings
    }

    private func wait(for description: String, timeout: TimeInterval = 5, until: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if until() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("не дождались: \(description)")
    }
}
