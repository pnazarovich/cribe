import AVFoundation
import XCTest
@testable import TranscriberCore

/// Движок-заглушка: `prepare` сообщает о загрузке и висит, пока тест его не отпустит —
/// как первая загрузка WhisperKit, которая специализируется под ANE минутами.
private final class GatedEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    /// Отпускает загрузку: `prepare` доходит до конца, как и в жизни (прервать его нечем).
    func release() { lock.withLock { released = true } }

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
        try await wait(for: "старт записи", timeout: 30) {
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

    /// Esc, нажатый пока конвейер уже считает: проход досчитывается в никуда — ни вставки,
    /// ни «последней диктовки», ни истории.
    func testEscapeDuringPipelineDiscardsResult() async throws {
        let recorder = StubRecorder()
        recorder.capturedSamples = try await Self.spokenSamples()
        let engine = HoldingEngine()
        let settings = makeSettings()
        settings.gptEnabled = false  // слой 3 в тестах в сеть не ходит
        let controller = makeController(engine: engine, recorder: recorder, settings: settings)

        controller.toggle()
        try await wait(for: "старт записи", timeout: 30) {
            if case .recording = controller.state { return true }
            return false
        }
        let historyBefore = HistoryStore.shared.items.count

        controller.toggle()  // стоп — дальше работает конвейер
        XCTAssertEqual(controller.state, .transcribing)
        controller.cancelDictation()

        // Движок держит проход до этого момента, поэтому Esc гарантированно раньше вставки.
        try await wait(for: "начало распознавания", timeout: 30) { engine.isTranscribing }
        engine.release()

        try await wait(for: "вспышку отмены", timeout: 30) { controller.state == .cancelled }
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

    // MARK: - Обвязка

    private func makeController(
        engine: TranscriptionEngine,
        recorder: AudioCapturing = StubRecorder(),
        settings: AppSettings? = nil
    ) -> DictationController {
        DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dictionaryURL),
            settings: settings ?? makeSettings(),
            recorder: recorder
        )
    }

    private func makeSettings() -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        // Тесты доходят до живой записи, а прогон звенеть чаймами не должен.
        settings.soundsEnabled = false
        return settings
    }

    /// Настоящая речь в PCM 16 кГц mono. Нужна затем, что синтетические сигналы Silero VAD
    /// речью не считает, а без вердикта VAD конвейер до распознавания не доходит вовсе.
    /// Синтез офлайновый и беззвучный (`write`, а не `speak`); что именно сказано — неважно,
    /// текст всё равно отдаёт движок-заглушка.
    private static func spokenSamples() async throws -> [Float] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "Testing dictation cancel")
        // Английский голос есть на любой macOS; без него синтез идёт голосом по умолчанию.
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        var samples: [Float] = []
        var converter: AVAudioConverter?

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // Пустой буфер — признак конца синтеза.
                guard pcm.frameLength > 0 else {
                    if !finished {
                        finished = true
                        continuation.resume()
                    }
                    return
                }
                if converter == nil { converter = AVAudioConverter(from: pcm.format, to: target) }
                guard let converter else { return }
                let capacity = AVAudioFrameCount(
                    Double(pcm.frameLength) * target.sampleRate / pcm.format.sampleRate + 1024
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var fed = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return pcm
                }
                guard let channel = converted.floatChannelData else { return }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
            }
        }
        withExtendedLifetime(synthesizer) {}
        // Молчаливый синтез превратился бы в непонятное «речь не обнаружена» посреди теста.
        XCTAssertGreaterThan(samples.count, AudioCaptureFormat.samples(seconds: 0.5))
        return samples
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
