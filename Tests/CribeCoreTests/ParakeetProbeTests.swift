import AVFoundation
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
        let samples = try Self.fixture()
        let engine = ParakeetEngine()

        let states = StateLog()
        let clock = Date()
        try await engine.prepare(language: .ru) { state in states.add(state) }
        note("PROBE: подготовка \(String(format: "%.2f", Date().timeIntervalSince(clock))) c, \(states.summary)")

        let pass = Date()
        let text = try await engine.transcribe(samples, language: .ru, prompt: "")
        note("PROBE: проход \(String(format: "%.2f", Date().timeIntervalSince(pass))) c, слов \(text.split(separator: " ").count)")
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

    /// Запись для пробы приходит переменной окружения: своих фикстур у пробы нет —
    /// проверять движок имеет смысл только на живой речи.
    private static func fixture() throws -> [Float] {
        guard let path = ProcessInfo.processInfo.environment["CRIBE_PROBE_WAV"] else {
            throw XCTSkip("нет CRIBE_PROBE_WAV")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let capacity = AVAudioFrameCount(
            Double(file.length) * format.sampleRate / file.processingFormat.sampleRate + 4096
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        var done = false
        var error: NSError?
        converter.convert(to: buffer, error: &error) { _, status in
            if done {
                status.pointee = .endOfStream
                return nil
            }
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )!
            try? file.read(into: input)
            done = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

}
