import XCTest
@testable import TranscriberCore

/// Движок-шпион для повторного разбора: запоминает, что именно ему дали.
/// Смысл повтора в том, чтобы пойти ДРУГИМ путём, — значит, проверять надо не результат,
/// а параметры вызова.
private final class RetranscribeSpy: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [Float] = []
    private var receivedPrompt: String?
    private var receivedVariant: String?
    private var preparedVariant: String?

    var samples: [Float] { lock.withLock { received } }
    var prompt: String? { lock.withLock { receivedPrompt } }
    var variant: String? { lock.withLock { receivedVariant } }
    var prepared: String? { lock.withLock { preparedVariant } }

    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        onState(.ready)
    }

    func prepare(
        variant: String,
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws {
        lock.withLock { preparedVariant = variant }
        onState(.ready)
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        try await transcribe(samples, language: language, variant: language.whisperModel, prompt: prompt)
    }

    func transcribe(
        _ samples: [Float],
        language: Language,
        variant: String,
        prompt: String
    ) async throws -> String {
        lock.withLock {
            received = samples
            receivedPrompt = prompt
            receivedVariant = variant
        }
        return "разобрано заново"
    }
}

/// Доставка-заглушка: буфер обмена пользователя тесты не трогают.
private final class CopySpy: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []

    var copied: [String] { lock.withLock { texts } }

    var delivery: TextDelivery {
        TextDelivery(
            focus: { FocusVerdict(state: .unknown, role: nil) },
            insert: { _ in .pasted },
            copy: { text in self.lock.withLock { self.texts.append(text) } }
        )
    }
}

@MainActor
final class RetranscribeTests: XCTestCase {
    private var dir: URL!
    private var suiteName: String!
    private var recordings: RecordingStore!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RetranscribeTests-\(UUID().uuidString)")
        suiteName = "RetranscribeTests-\(UUID().uuidString)"
        recordings = RecordingStore(folder: dir.appendingPathComponent("recordings"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Повтор идёт другим путём: весь буфер целиком, без обрезки воротами речи и без
    /// словарного промпта — именно промпт и съедал слова на первом проходе.
    func testRetranscribeUsesPlainFullPassWithoutPrompt() async throws {
        let spy = RetranscribeSpy()
        let controller = makeController(engine: spy)
        let item = try saveRecording(seconds: 3, language: .ru)

        let text = try await controller.retranscribe(item: item, mode: .samePlainPass)

        XCTAssertEqual(text, "разобрано заново")
        XCTAssertEqual(spy.prompt, "", "словарный промпт на повторе не нужен")
        XCTAssertEqual(spy.variant, Language.ru.whisperModel, "модель по умолчанию — та же")
        // Ворота речи не звали: буфер дошёл до движка целиком.
        XCTAssertEqual(spy.samples.count, AudioCaptureFormat.samples(seconds: 3))
    }

    /// Тихую запись повтор поднимает по уровню — ровно того ей и не хватало в первый раз.
    func testRetranscribeNormalizesQuietRecording() async throws {
        let spy = RetranscribeSpy()
        let controller = makeController(engine: spy)
        let item = try saveRecording(seconds: 3, language: .ru, peak: 0.05)

        _ = try await controller.retranscribe(item: item, mode: .samePlainPass)

        XCTAssertEqual(AudioNormalizer.peak(spy.samples), AudioNormalizer.targetPeak, accuracy: 0.05)
    }

    /// Большая модель берётся для того же языка, а не вместе с чужим: русскую диктовку
    /// нельзя разбирать украинским декодером только потому, что модель называется large-v3.
    func testLargeModelKeepsTheLanguage() async throws {
        let spy = RetranscribeSpy()
        let controller = makeController(engine: spy)
        let item = try saveRecording(seconds: 3, language: .ru)

        _ = try await controller.retranscribe(item: item, mode: .largeModel)

        XCTAssertEqual(spy.variant, WhisperModel.large)
        XCTAssertEqual(spy.prepared, WhisperModel.large)
    }

    /// Новый текст уезжает в буфер обмена и заменяет старый в истории — второй строки
    /// на ту же диктовку не появляется.
    func testResultReplacesHistoryRowAndReachesClipboard() async throws {
        let spy = RetranscribeSpy()
        let copies = CopySpy()
        let controller = makeController(engine: spy, delivery: copies)
        let item = try saveRecording(seconds: 3, language: .ru)
        let history = HistoryStore.shared
        let before = history.items.count

        _ = try await controller.retranscribe(item: item, mode: .samePlainPass)

        XCTAssertEqual(copies.copied, ["разобрано заново"])
        XCTAssertEqual(history.items.count, before, "повтор не заводит вторую строку")
        XCTAssertEqual(controller.lastOriginal, "разобрано заново")
    }

    /// Записи уже нет (вытеснена кольцом) — честная ошибка, а не пустой разбор тишины.
    func testMissingRecordingFails() async throws {
        let controller = makeController(engine: RetranscribeSpy())
        let item = HistoryItem(text: "", language: .ru, audio: "нет-такой.wav", seconds: 40)

        do {
            _ = try await controller.retranscribe(item: item, mode: .samePlainPass)
            XCTFail("повтор без записи обязан упасть")
        } catch {
            XCTAssertTrue(error is RecordingStoreError)
        }
    }

    // MARK: - Вспомогательное

    private func makeController(engine: TranscriptionEngine, delivery: CopySpy = CopySpy()) -> DictationController {
        let settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        settings.gptEnabled = false
        settings.soundsEnabled = false
        return DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dir.appendingPathComponent("dictionary.json")),
            settings: settings,
            recorder: SilentRecorder(),
            delivery: delivery.delivery,
            makeVad: { FailingVad() },
            recordings: recordings
        )
    }

    /// Кладёт запись в хранилище и возвращает строку истории, которая на неё смотрит.
    private func saveRecording(seconds: Double, language: Language, peak: Float = 0.5) throws -> HistoryItem {
        let count = AudioCaptureFormat.samples(seconds: seconds)
        let samples = (0..<count).map { peak * sin(Float($0) * 0.05) }
        let saved = try XCTUnwrap(recordings.save(samples, keeping: 3))
        return HistoryItem(text: "", language: language, audio: saved.name, seconds: saved.seconds)
    }
}

/// Ворота речи, которые упали бы, если бы их позвали: повтор обязан идти мимо них.
private struct FailingVad: SpeechGating {
    func trimmed(_ samples: [Float]) async throws -> [Float]? {
        XCTFail("повторный разбор не должен звать ворота речи")
        return nil
    }

    func resetStream() async {}
    func feedStream(_ chunk: [Float]) async throws -> Bool { false }
}

private final class SilentRecorder: AudioCapturing, @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    var capturedSamples: [Float] = []
    var capturedSilence = false
    var capturedSampleCount: Int { capturedSamples.count }

    func setInputDevice(uid: String?) {}
    func prepare() {}
    func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws {}
    func stop() -> [Float] { capturedSamples }
    func teardown() {}
}
