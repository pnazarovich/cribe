import XCTest
@testable import TranscriberCore

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

/// Доставка-заглушка: считает вставки и копирования, но ни разу не трогает ни буфер обмена
/// пользователя, ни чужие окна. Вердикт детектора задаётся тестом.
private final class SpyDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var insertedTexts: [String] = []
    private var copiedTexts: [String] = []
    private let focus: FocusState

    init(focus: FocusState) {
        self.focus = focus
    }

    var inserted: [String] { lock.withLock { insertedTexts } }
    var copied: [String] { lock.withLock { copiedTexts } }

    var delivery: TextDelivery {
        TextDelivery(
            focus: { FocusVerdict(state: self.focus, role: nil) },
            insert: { text in
                self.lock.withLock { self.insertedTexts.append(text) }
                return .pasted
            },
            copy: { text in self.lock.withLock { self.copiedTexts.append(text) } }
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

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DictationControllerTests-\(UUID().uuidString)")
        dictionaryURL = dir.appendingPathComponent("dictionary.json")
        suiteName = "DictationControllerTests-\(UUID().uuidString)"
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

    /// Тумблер «Смешанная речь» доезжает до промпта распознавания — это всё, чем он работает
    /// (модель он не меняет: замер показал, что large-v3 украинские вкрапления не вытягивает,
    /// а стоит 5.5× времени прохода). Без образца в промпте украинские слова русифицируются.
    func testMixedSpeechSettingReachesRecognitionPrompt() async throws {
        let mixed = try await sessionPrompt(mixedSpeech: true)
        let plain = try await sessionPrompt(mixedSpeech: false)

        XCTAssertTrue(mixed.contains("Українською"))
        XCTAssertFalse(plain.contains("Українською"))
    }

    /// Промпт, с которым сессия дошла до распознавания.
    private func sessionPrompt(mixedSpeech: Bool) async throws -> String {
        let engine = PromptSpyEngine()
        let settings = makeSettings()
        settings.mixedSpeech = mixedSpeech
        let controller = DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dictionaryURL),
            settings: settings,
            recorder: recordedThreeSeconds(),
            delivery: SpyDelivery(focus: .unknown).delivery,
            makeVad: { PassThroughVad() }
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
            recorder: recorder
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

    /// Esc, нажатый пока конвейер уже считает: проход досчитывается в никуда — ни вставки,
    /// ни «последней диктовки», ни истории.
    func testEscapeDuringPipelineDiscardsResult() async throws {
        let recorder = StubRecorder()
        recorder.capturedSamples = [Float](repeating: 0.1, count: AudioCaptureFormat.samples(seconds: 3))
        let engine = HoldingEngine()
        let controller = makeController(engine: engine, recorder: recorder)

        controller.toggle()
        try await wait(for: "старт записи") {
            if case .recording = controller.state { return true }
            return false
        }
        let historyBefore = HistoryStore.shared.items.count

        controller.toggle()  // стоп — дальше работает конвейер
        XCTAssertEqual(controller.state, .transcribing)
        controller.cancelDictation()

        // Движок держит проход до этого момента, поэтому Esc гарантированно раньше вставки.
        try await wait(for: "начало распознавания") { engine.isTranscribing }
        engine.release()

        try await wait(for: "вспышку отмены") { controller.state == .cancelled }
        // `lastOriginal` присваивается ровно перед вставкой: раз его нет, не было и вставки
        // с буфером обмена.
        XCTAssertNil(controller.lastOriginal)
        XCTAssertNil(controller.lastTranslation)
        XCTAssertEqual(HistoryStore.shared.items.count, historyBefore)
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
        cardsWhenNoField: Bool = true
    ) -> DictationController {
        let settings = makeSettings()
        settings.cardsWhenNoField = cardsWhenNoField
        return DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dictionaryURL),
            settings: settings,
            recorder: recorder,
            delivery: delivery.delivery,
            // Заглушка вместо Silero: прогон не поднимает CoreML-модель и не ходит за ней в сеть.
            makeVad: { PassThroughVad() }
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
