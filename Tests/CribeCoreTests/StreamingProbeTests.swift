import AVFoundation
import XCTest
@testable import CribeCore

/// Проба (не часть обычного прогона): требует фикстуру в CRIBE_PROBE_WAV
/// и скачанную большую модель. Сравнивает потоковую финализацию с обычным полным проходом.
final class StreamingProbeTests: XCTestCase {

    func testStreamingFinalizationMatchesPlainDecode() async throws {
        guard let path = ProcessInfo.processInfo.environment["CRIBE_PROBE_WAV"] else {
            throw XCTSkip("нет CRIBE_PROBE_WAV")
        }
        let samples = try Self.load(URL(fileURLWithPath: path))
        let rate = AudioCaptureFormat.sampleRate
        print("PROBE: аудио \(samples.count) сэмплов = \(Double(samples.count) / rate) c")

        let engine = WhisperEngine()
        try await engine.prepare(language: .ru) { _ in }
        let vad = try await VadGate()
        let prompt = PromptBuilder.initialPrompt(entries: [], language: .ru)

        // --- Обычный путь: обрезка всего буфера + полный проход на стопе.
        var clock = Date()
        guard let speech = try await vad.trimmed(samples) else {
            return XCTFail("VAD не нашёл речи в фикстуре")
        }
        let plain = try await engine.transcribe(speech, language: .ru, prompt: prompt)
        let plainStopToText = Date().timeIntervalSince(clock)

        // --- Потоковый путь: проходы по растущему буферу 2 → 12 c ещё во время записи.
        var confirmedText = ""
        var confirmedEnd = 0
        var lastPass: TimeInterval = 0
        for seconds in stride(from: 2.0, through: 12.0, by: 2.0) {
            let count = min(Int(seconds * rate), samples.count)
            clock = Date()
            let segments = try await engine.transcribeSegments(
                Array(samples[0..<count]),
                language: .ru,
                prompt: prompt
            )
            lastPass = Date().timeIntervalSince(clock)
            print("PROBE:   сегменты \(segments.map { "\($0.start)–\($0.end)" }.joined(separator: ", "))")
            guard let pass = StreamingMerge.confirmed(from: segments), pass.endSample > confirmedEnd else {
                print("PROBE: проход \(seconds) c — подтверждать нечего (\(lastPass) c)")
                continue
            }
            confirmedEnd = pass.endSample
            confirmedText = pass.text
            print("PROBE: проход \(seconds) c за \(lastPass) c → подтверждено до \(Double(confirmedEnd) / rate) c")
        }

        // --- Стоп: остаётся только хвост с нахлёстом 0.5 c.
        XCTAssertGreaterThan(confirmedEnd, 0, "фоновые проходы не подтвердили ничего")
        XCTAssertLessThan(confirmedEnd, samples.count)
        clock = Date()
        let start = max(0, confirmedEnd - Int(0.5 * rate))
        guard let tail = try await vad.trimmed(Array(samples[start...])) else {
            return XCTFail("VAD не нашёл речи в хвосте")
        }
        let tailText = try await engine.transcribe(tail, language: .ru, prompt: prompt)
        let merged = StreamingMerge.merge(confirmed: confirmedText, tail: tailText)
        let streamedStopToText = Date().timeIntervalSince(clock)

        print("PROBE: полный проход  \(plainStopToText) c → \(plain)")
        print("PROBE: хвост \(Double(samples.count - start) / rate) c за \(streamedStopToText) c → \(tailText)")
        print("PROBE: склейка → \(merged)")
        print("PROBE: последний фоновый проход \(lastPass) c (его стоп ждёт в худшем случае)")
        print("PROBE: слов: полный \(ShortDictation.wordCount(plain)), потоковый \(ShortDictation.wordCount(merged))")
    }

    private static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
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
