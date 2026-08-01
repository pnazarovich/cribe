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

    // MARK: - Обвязка

    private func makeController(engine: TranscriptionEngine) -> DictationController {
        DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dictionaryURL),
            settings: AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
        )
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
