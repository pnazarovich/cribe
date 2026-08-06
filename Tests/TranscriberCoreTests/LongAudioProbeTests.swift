import AVFoundation
import XCTest
@testable import TranscriberCore

/// Измерительный стенд длинной диктовки. Не часть обычного прогона: без
/// `TRANSCRIBER_PROBE_WAV` все три пробы пропускаются.
///
/// ```
/// say -v Milena -r 220 -f текст.txt -o длинная.wav --data-format=LEI16@16000 --file-format=WAVE
/// TRANSCRIBER_PROBE_WAV=длинная.wav swift test --disable-keychain --filter LongAudioProbeTests
/// ```
///
/// Считает одно и то же число — сколько слов доехало до текста — по трём осям: длина промпта
/// (`testPromptBudget`), громкость записи (`testQuietRecording`) и путь конвейера
/// (`testPathsOnLongDictation`). Именно по этим трём замерам выбраны
/// `WhisperEngine.maxPromptTokens` и параметры `AudioNormalizer`.
///
/// Печатаем в stderr: stdout у прогона тестов перехватывается и до консоли не доходит.
private func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

final class LongAudioProbeTests: XCTestCase {

    private static let rate = AudioCaptureFormat.sampleRate

    /// Все четыре пути на одной фикстуре и одной прогретой модели.
    func testPathsOnLongDictation() async throws {
        let samples = try Self.fixture()
        let language = Self.language
        let engine = WhisperEngine()
        try await engine.prepare(language: language) { _ in }
        let vad = try await VadGate()

        let entries = UserDictionary(url: UserDictionary.defaultURL).entries
        let prompt = PromptBuilder.initialPrompt(entries: entries, language: language)
        note("PROBE: словарь \(entries.count) терминов, промпт \(prompt.count) симв.")

        // 1. Сегменты по всему буферу — верхняя планка: столько речи модель вообще видит.
        let segments = try await engine.transcribeSegments(samples, language: language, prompt: prompt)
        Self.report("сегменты по всему буферу", samples: samples, segments: segments)

        // 2. Обычный (не потоковый) путь конвейера: VAD-обрезка + один `transcribe`.
        guard let speech = try await vad.trimmed(samples) else {
            return XCTFail("VAD не нашёл речи")
        }
        note("PROBE: VAD оставил \(Self.seconds(speech.count)) c из \(Self.seconds(samples.count)) c")
        let plain = try await engine.transcribe(speech, language: language, prompt: prompt)
        note("PROBE: обычный путь: слов \(ShortDictation.wordCount(plain))")
        note("PROBE:   \(plain)")

        // 3. Потоковый путь ровно так, как его гоняет `DictationController`.
        let streamed = try await Self.emulateStreaming(
            samples: samples,
            engine: engine,
            vad: vad,
            language: language,
            prompt: prompt
        )
        note("PROBE: потоковый путь: слов \(ShortDictation.wordCount(streamed))")
        note("PROBE:   \(streamed)")
    }

    /// Тихая запись (низкая громкость входа в системе): что видят ворота речи и что
    /// доходит до текста — до нормализации и после неё.
    func testQuietRecording() async throws {
        let samples = try Self.fixture()
        let language = Self.language
        let engine = WhisperEngine()
        try await engine.prepare(language: language) { _ in }
        let vad = try await VadGate()
        // Промпт короткий намеренно: длинный съедает бюджет токенов декодера и сам по себе
        // рвёт текст (см. `testPromptBudget`) — на его фоне эффект нормализации не разглядеть.
        let prompt = PromptBuilder.initialPrompt(entries: [], language: language)

        for divisor: Float in [1, 4, 8, 16, 32, 64] {
            let quiet = divisor == 1 ? samples : samples.map { $0 / divisor }
            var peak: Float = 0
            for value in quiet where abs(value) > peak { peak = abs(value) }

            let speech = try await vad.trimmed(quiet)
            let heard = speech.map { Self.seconds($0.count) } ?? "НЕТ РЕЧИ"
            let text = try await engine.transcribe(quiet, language: language, prompt: prompt)

            let loud = AudioNormalizer.normalized(quiet)
            let loudSpeech = try await vad.trimmed(loud)
            let loudHeard = loudSpeech.map { Self.seconds($0.count) } ?? "НЕТ РЕЧИ"
            let loudText = try await engine.transcribe(loud, language: language, prompt: prompt)

            note(
                """
                PROBE: ÷\(Int(divisor)) пик \(String(format: "%.4f", peak)) \
                → ворота \(heard) c, слов \(ShortDictation.wordCount(text)) \
                | после нормализации (×\(String(format: "%.1f", AudioNormalizer.gain(forPeak: peak))), \
                пик \(String(format: "%.3f", AudioNormalizer.peak(loud)))) \
                → ворота \(loudHeard) c, слов \(ShortDictation.wordCount(loudText))
                """
            )
        }
    }

    /// Сколько речи теряется в зависимости от длины промпта: он ест тот же бюджет токенов
    /// декодера (224 на окно), что и сама расшифровка окна.
    func testPromptBudget() async throws {
        let samples = try Self.fixture()
        let language = Self.language
        let engine = WhisperEngine()
        try await engine.prepare(language: language) { _ in }
        let entries = UserDictionary(url: UserDictionary.defaultURL).entries

        for count in [0, 6, 12, 24, entries.count] {
            let prompt = PromptBuilder.initialPrompt(entries: Array(entries.prefix(count)), language: language)
            let segments = try await engine.transcribeSegments(samples, language: language, prompt: prompt)
            let text = segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            note(
                """
                PROBE: терминов \(count), промпт \(prompt.count) симв. \
                → слов \(ShortDictation.wordCount(text)), сегментов \(segments.count)
                """
            )
        }
    }

    /// Эмуляция потоковой финализации: фоновые проходы по растущему буферу идут в реальном
    /// времени (буфер прирастает ровно на то время, что считался предыдущий проход),
    /// затем хвост и склейка — как в `DictationController.streamedTranscript`.
    private static func emulateStreaming(
        samples: [Float],
        engine: WhisperEngine,
        vad: VadGate,
        language: Language,
        prompt: String
    ) async throws -> String {
        let minStart = Double(DictationController.streamingMinSamples) / rate
        let growth = Double(DictationController.rollingGrowth) / rate
        let maxStart = Double(DictationController.rollingMaxSamples) / rate
        let gap = DictationController.rollingGap

        var confirmedText = ""
        var confirmedEnd = 0
        var buffer = minStart              // столько записано к моменту первого прохода
        var lastPass = 0.0

        while buffer <= maxStart {
            let count = min(Int(buffer * rate), samples.count)
            let clock = Date()
            let segments = try await engine.transcribeSegments(
                Array(samples[0..<count]),
                language: language,
                prompt: prompt
            )
            let spent = Date().timeIntervalSince(clock)
            lastPass = buffer

            if let pass = StreamingMerge.confirmed(from: segments), pass.endSample > confirmedEnd {
                confirmedEnd = pass.endSample
                confirmedText = pass.text
                note(
                    """
                    PROBE:   проход по \(fmt(buffer)) c за \(fmt(spent)) c \
                    → подтверждено до \(fmt(Double(confirmedEnd) / rate)) c, \
                    слов \(ShortDictation.wordCount(pass.text))
                    """
                )
            } else {
                note("PROBE:   проход по \(fmt(buffer)) c за \(fmt(spent)) c → подтверждать нечего")
            }

            // Пока считали, запись шла: буфер вырос на время прохода плюс передышку.
            buffer += spent + gap
            // …и до порога прироста фоновый цикл просто ждёт.
            buffer = max(buffer, lastPass + growth)
            if count >= samples.count { break }
        }

        let total = Double(samples.count) / rate
        note(
            """
            PROBE: фоновые проходы кончились, подтверждено \
            \(fmt(Double(confirmedEnd) / rate)) c из \(fmt(total)) c записи
            """
        )
        guard confirmedEnd > 0, !confirmedText.isEmpty, confirmedEnd < samples.count else {
            note("PROBE: потоковый путь не включился — конвейер пойдёт полным проходом")
            return ""
        }

        let start = max(0, confirmedEnd - DictationController.tailOverlap)
        note("PROBE: хвост \(fmt(Double(samples.count - start) / rate)) c")
        guard let tail = try await vad.trimmed(Array(samples[start...])) else {
            note("PROBE: VAD не нашёл речи в хвосте — откат на полный проход")
            return ""
        }
        let tailText = try await engine.transcribe(tail, language: language, prompt: prompt)
        note("PROBE: хвост распознан, слов \(ShortDictation.wordCount(tailText))")
        return StreamingMerge.merge(confirmed: confirmedText, tail: tailText)
    }

    // MARK: - Вспомогательное

    static var language: Language {
        Language(rawValue: ProcessInfo.processInfo.environment["TRANSCRIBER_PROBE_LANG"] ?? "ru") ?? .ru
    }

    static func fixture() throws -> [Float] {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIBER_PROBE_WAV"] else {
            throw XCTSkip("нет TRANSCRIBER_PROBE_WAV")
        }
        let samples = try load(URL(fileURLWithPath: path))
        note("PROBE: аудио \(samples.count) сэмплов = \(seconds(samples.count)) c")
        return samples
    }

    static func report(_ title: String, samples: [Float], segments: [ASRSegment]) {
        note("PROBE: --- \(title): \(segments.count) сегментов ---")
        var covered = 0.0
        var cursor = 0.0
        for segment in segments {
            let gap = segment.start - cursor
            if gap > 0.35 {
                note("PROBE:   ДЫРА \(fmt(cursor))–\(fmt(segment.start)) = \(fmt(gap)) c")
            }
            covered += max(0, segment.end - max(segment.start, cursor))
            cursor = max(cursor, segment.end)
            note("PROBE:   [\(fmt(segment.start))–\(fmt(segment.end))] \(segment.text)")
        }
        let total = Double(samples.count) / rate
        if total - cursor > 0.35 {
            note("PROBE:   ДЫРА В ХВОСТЕ \(fmt(cursor))–\(fmt(total)) = \(fmt(total - cursor)) c")
        }
        let text = segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        note(
            "PROBE: \(title): покрыто \(fmt(covered)) c из \(fmt(total)) c, слов \(ShortDictation.wordCount(text))"
        )
    }

    static func seconds(_ count: Int) -> String { fmt(Double(count) / rate) }

    static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
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
