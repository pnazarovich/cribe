import XCTest
@testable import CribeCore

/// Живая проба движка Parakeet на настоящей записи. Не часть обычного прогона: без
/// `CRIBE_PROBE_WAV` пропускается, потому что требует модели на диске (~600 МБ).
///
/// ```
/// CRIBE_PROBE_WAV=запись.wav swift test --disable-keychain --filter ParakeetProbeTests
/// ```
final class ParakeetProbeTests: XCTestCase {
    private func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Весь путь движка: подготовка (с состояниями), проход, отказ от перевода.
    func testTranscribesRealRecording() async throws {
        let samples = try LongAudioProbeTests.fixture()
        let engine = ParakeetEngine()

        let states = StateLog()
        let clock = Date()
        try await engine.prepare(language: .ru) { state in states.add(state) }
        note("PROBE: подготовка \(String(format: "%.2f", Date().timeIntervalSince(clock))) c, \(states.summary)")

        let pass = Date()
        let text = try await engine.transcribe(samples, language: .ru, prompt: "")
        note("PROBE: проход \(String(format: "%.2f", Date().timeIntervalSince(pass))) c, слов \(ShortDictation.wordCount(text))")
        note("PROBE:   \(text)")

        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Parakeet вернул пустоту")
        // Последнее состояние — всегда `.ready`: на нём панель гасит «Готовлю модель…».
        guard case .ready = states.last else { return XCTFail("подготовка кончилась не готовностью") }

        // Перевод — не его работа, и он обязан сказать это вслух, а не вернуть русский текст.
        do {
            _ = try await engine.transcribe(samples, language: .ru, prompt: "", translating: true)
            XCTFail("перевод не должен получиться")
        } catch TranscriptionEngineError.translationUnsupported {}
    }

    /// Состояния приезжают с чужой очереди — собираем их под замком.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [ASRModelState] = []

        func add(_ state: ASRModelState) {
            lock.lock()
            defer { lock.unlock() }
            states.append(state)
        }

        var last: ASRModelState? {
            lock.lock()
            defer { lock.unlock() }
            return states.last
        }

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            return "состояний \(states.count)"
        }
    }
}
