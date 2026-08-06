import XCTest
@testable import TranscriberCore

/// Движок, который сообщает о прогреве дважды — как настоящий, когда `prepare` зовут
/// повторно. Между сообщениями ждёт теста: так проверка не зависит от таймингов.
private final class TwiceLoadingEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false

    /// Отпускает движок ко второму сообщению о прогреве.
    func proceed() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }

    func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        onState(.loading)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                if opened { return true }
                gate = continuation
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
        onState(.loading)
        // Дальше не идём: тест смотрит именно на стадию прогрева.
        while true {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String { "" }
}

@MainActor
final class ModelWarmingTests: XCTestCase {
    /// Повторное сообщение о прогреве не начинает отсчёт заново: иначе счётчик секунд
    /// в панели прыгал бы на ноль, и прогрев выглядел бы бесконечным.
    func testRepeatedWarmingKeepsTheFirstStart() async throws {
        let engine = TwiceLoadingEngine()
        let suite = "ModelWarmingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dictionaryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(suite).json")
        defer { try? FileManager.default.removeItem(at: dictionaryURL) }

        let controller = DictationController(
            engine: engine,
            dictionary: UserDictionary(url: dictionaryURL),
            settings: AppSettings(defaults: defaults)
        )

        // Диктовка начинается с подготовки модели — на ней движок нас и удержит.
        controller.toggle()

        let first = try await warmingStart(of: controller)
        engine.proceed()
        // Ждём именно второе сообщение: до него проверка ничего не доказывает.
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try await warmingStart(of: controller)

        XCTAssertEqual(first, second, "отсчёт прогрева обязан идти от первого сообщения")
    }

    private func warmingStart(of controller: DictationController) async throws -> Date {
        for _ in 0..<200 {
            if case .preparingModel(.warming(let since)) = controller.state { return since }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("прогрев так и не начался")
        return Date()
    }
}
