import Foundation
import XCTest
@testable import CribeCore

/// Чистые части движка GigaAM — без сети и без модели на диске: фронтенд, нарезка, декодер.
final class GigaAMEngineTests: XCTestCase {
    // MARK: - Фронтенд

    /// Периодический Ханн и стандартный HTK-банк torchaudio. Настоящие таблицы пакета —
    /// они же, округлённые до bfloat16 (см. `GigaAMFrontend`).
    private static func hann() -> [Float] {
        (0..<320).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 320)) }
    }

    private static func htkFilterbank() -> [Float] {
        func hzToMel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func melToHz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let top = hzToMel(8000)
        let points = (0..<66).map { melToHz(top * Double($0) / 65) }
        var fb = [Float](repeating: 0, count: 161 * 64)
        for k in 0..<161 {
            let f = 8000 * Double(k) / 160
            for m in 0..<64 {
                let down = (f - points[m]) / (points[m + 1] - points[m])
                let up = (points[m + 2] - f) / (points[m + 2] - points[m + 1])
                fb[k * 64 + m] = Float(max(0, min(down, up)))
            }
        }
        return fb
    }

    private func makeFrontend() throws -> GigaAMFrontend {
        try GigaAMFrontend(window: Self.hann(), filterbank: Self.htkFilterbank())
    }

    private static func sine(hz: Double, amplitude: Double, count: Int) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / 16_000)) }
    }

    func testFrameCountMatchesGigaAMFormula() {
        XCTAssertEqual(GigaAMFrontend.frameCount(samples: 0), 0)
        XCTAssertEqual(GigaAMFrontend.frameCount(samples: 319), 0)
        XCTAssertEqual(GigaAMFrontend.frameCount(samples: 320), 1)
        XCTAssertEqual(GigaAMFrontend.frameCount(samples: 479), 1)
        XCTAssertEqual(GigaAMFrontend.frameCount(samples: 480), 2)
        // Окно модели — вход [1, 64, 2499].
        XCTAssertEqual(GigaAMFrontend.windowSamples, 400_000)
        XCTAssertEqual(GigaAMFrontend.windowFrames, 2499)
    }

    func testLogMelShapeAndPadding() throws {
        let frontend = try makeFrontend()
        let audio = Self.sine(hz: 1000, amplitude: 0.5, count: 16_000)
        let plain = frontend.logMel(audio[...])
        XCTAssertEqual(plain.count, 64 * 99)

        let padded = frontend.logMel(audio[...], paddedTo: GigaAMFrontend.windowSamples)
        XCTAssertEqual(padded.count, 64 * 2499)
        // Кадры в дополнении — чистая тишина: log(1e-9).
        let floor = log(Float(1e-9))
        for m in 0..<64 {
            XCTAssertEqual(padded[m * 2499 + 2000], floor, accuracy: 1e-4)
            // Настоящие кадры совпадают с расчётом без дополнения.
            XCTAssertEqual(padded[m * 2499 + 50], plain[m * 99 + 50], accuracy: 1e-5)
        }
    }

    /// Синус ровно на частоте бина: у периодического Ханна вся энергия — в бине k
    /// (|X|² = (A·N/4)²) и в соседях (A·N/8)², остальные — ноль.
    func testPowerSpectrumOfBinCenteredSine() throws {
        let frontend = try makeFrontend()
        let amplitude = 0.5
        // Бин k = 20 → 20 · 50 Гц = 1000 Гц. Косинус, чтобы фаза не мешала: |X| от фазы не зависит.
        let frame = (0..<320).map { Float(amplitude * cos(2 * Double.pi * 20 * Double($0) / 320)) }
        let power = frontend.powerSpectrum(frame)
        XCTAssertEqual(power.count, 161)
        XCTAssertEqual(power[20], Float(pow(amplitude * 320 / 4, 2)), accuracy: 0.05) // 1600
        XCTAssertEqual(power[19], Float(pow(amplitude * 320 / 8, 2)), accuracy: 0.05) // 400
        XCTAssertEqual(power[21], Float(pow(amplitude * 320 / 8, 2)), accuracy: 0.05)
        for k in 0..<161 where abs(k - 20) > 1 {
            XCTAssertEqual(power[k], 0, accuracy: 1e-3, "бин \(k)")
        }
    }

    /// Мощность совпадает с прямым DFT в Double — в том числе DC и Найквист, которые
    /// vDSP упаковывает в один комплексный элемент.
    func testPowerSpectrumMatchesNaiveDFT() throws {
        let frontend = try makeFrontend()
        let window = Self.hann()
        let frame: [Float] = (0..<320).map { i in
            let x = Double(i)
            let value: Double = sin(x * 0.37) + 0.3 * cos(x * 1.1) + 0.2 + (i % 2 == 0 ? 0.05 : -0.05)
            return Float(value)
        }
        let power = frontend.powerSpectrum(frame)
        for k in [0, 1, 5, 59, 100, 159, 160] {
            var re = 0.0
            var im = 0.0
            for i in 0..<320 {
                let angle = -2 * Double.pi * Double(k * i) / 320
                let x = Double(frame[i]) * Double(window[i])
                re += x * cos(angle)
                im += x * sin(angle)
            }
            let expected = re * re + im * im
            XCTAssertEqual(Double(power[k]), expected, accuracy: max(1e-3, expected * 1e-4), "бин \(k)")
        }
    }

    /// Синус 1 кГц: максимум — в мел-полосе, чей центр ближе всего к 1 кГц, а значение
    /// равно log(Σ fb·|X|²) по трём бинам с энергией.
    func testLogMelOfSinePeaksAtExpectedBand() throws {
        let frontend = try makeFrontend()
        let fb = Self.htkFilterbank()
        let audio = (0..<3200).map { Float(0.5 * cos(2 * Double.pi * 1000 * Double($0) / 16_000)) }
        let features = frontend.logMel(audio[...])
        let frames = GigaAMFrontend.frameCount(samples: 3200)
        XCTAssertEqual(features.count, 64 * frames)

        let column = (0..<64).map { features[$0 * frames + 3] }
        let peak = column.indices.max { column[$0] < column[$1] }!
        let strongest = (0..<64).max { fb[20 * 64 + $0] < fb[20 * 64 + $1] }!
        XCTAssertEqual(peak, strongest)

        let expected = log(1600 * fb[20 * 64 + peak] + 400 * fb[19 * 64 + peak] + 400 * fb[21 * 64 + peak])
        XCTAssertEqual(column[peak], expected, accuracy: 1e-3)
        // Полосы далеко от 1 кГц — пол логарифма (энергии там нет).
        XCTAssertLessThan(column[63], -10)
    }

    func testLogMelClampsSilenceAndTooShortInput() throws {
        let frontend = try makeFrontend()
        let silence = frontend.logMel([Float](repeating: 0, count: 640)[...])
        XCTAssertEqual(silence.count, 64 * 3)
        XCTAssertTrue(silence.allSatisfy { abs($0 - log(Float(1e-9))) < 1e-4 })
        XCTAssertTrue(frontend.logMel([Float](repeating: 0.1, count: 100)[...]).isEmpty)
    }

    func testRejectsTransposedFilterbank() {
        let fb = Self.htkFilterbank()
        var transposed = [Float](repeating: 0, count: fb.count)
        for k in 0..<161 {
            for m in 0..<64 { transposed[m * 161 + k] = fb[k * 64 + m] }
        }
        XCTAssertNoThrow(try GigaAMFrontend.checkLayout(fb))
        XCTAssertThrowsError(try GigaAMFrontend.checkLayout(transposed))
        XCTAssertThrowsError(try GigaAMFrontend(window: [Float](repeating: 1, count: 400), filterbank: fb))
    }

    // MARK: - Нарезка

    func testShortAudioIsOneWindow() {
        XCTAssertEqual(GigaAMChunker.windows([]), [])
        let audio = [Float](repeating: 0.1, count: 400_000)
        XCTAssertEqual(GigaAMChunker.windows(audio), [.init(audio: 0..<400_000, keep: 0..<400_000)])
    }

    /// Общие свойства нарезки: окна не длиннее 25 с, свои части покрывают запись встык,
    /// у каждой своей части есть контекст (слева 3 с, справа не меньше 3 с, кроме краёв).
    private func assertValid(_ windows: [GigaAMChunker.Window], count: Int, file: StaticString = #filePath, line: UInt = #line) {
        var cursor = 0
        for (index, window) in windows.enumerated() {
            XCTAssertLessThanOrEqual(window.audio.count, GigaAMFrontend.windowSamples, file: file, line: line)
            XCTAssertEqual(window.keep.lowerBound, cursor, file: file, line: line)
            XCTAssertTrue(window.audio.lowerBound <= window.keep.lowerBound && window.keep.upperBound <= window.audio.upperBound,
                          file: file, line: line)
            // Контекст слева — 3 с (до 40 мс больше: начало окна выровнено на сетку кадров).
            let left = window.keep.lowerBound - window.audio.lowerBound
            XCTAssertGreaterThanOrEqual(left, min(window.keep.lowerBound, GigaAMChunker.leftContext), file: file, line: line)
            XCTAssertLessThan(left, GigaAMChunker.leftContext + GigaAMChunker.samplesPerStep, file: file, line: line)
            XCTAssertEqual(window.audio.lowerBound % GigaAMChunker.samplesPerStep, 0, file: file, line: line)
            if index < windows.count - 1 {
                XCTAssertGreaterThanOrEqual(window.audio.upperBound - window.keep.upperBound, GigaAMChunker.rightContext,
                                            file: file, line: line)
                XCTAssertGreaterThanOrEqual(window.keep.count, GigaAMChunker.minKeep, file: file, line: line)
            } else {
                XCTAssertEqual(window.audio.upperBound, count, file: file, line: line)
            }
            cursor = window.keep.upperBound
        }
        XCTAssertEqual(cursor, count, file: file, line: line)
    }

    /// Тон с паузой на 20-й секунде: граница своих частей — в паузе.
    func testLongAudioIsSplitInsidePause() {
        var audio = Self.sine(hz: 300, amplitude: 0.3, count: 40 * 16_000)
        let pause = (20 * 16_000)..<(20 * 16_000 + 8_000) // 0,5 с тишины
        for i in pause { audio[i] = 0 }
        let windows = GigaAMChunker.windows(audio)
        XCTAssertEqual(windows.count, 2)
        assertValid(windows, count: audio.count)
        XCTAssertTrue(pause.contains(windows[0].keep.upperBound), "граница \(windows[0].keep.upperBound) вне паузы")
    }

    /// Сплошной звук без пауз: границы всё равно есть, окна в допустимых пределах.
    func testContinuousAudioStillFitsWindows() {
        for seconds in [26, 40, 70, 101] {
            let audio = Self.sine(hz: 440, amplitude: 0.3, count: seconds * 16_000)
            let windows = GigaAMChunker.windows(audio)
            XCTAssertGreaterThanOrEqual(windows.count, 2, "\(seconds) с")
            assertValid(windows, count: audio.count)
        }
    }

    /// Кадры энкодера (по 640 отсчётов) делятся между окнами по времени: каждый кадр
    /// записи достаётся ровно одному окну, без дублей и дыр. Начала окон кратны 640.
    func testKeptStepsPartitionTime() {
        let windows = [
            GigaAMChunker.Window(audio: 0..<400_000, keep: 0..<300_000),
            GigaAMChunker.Window(audio: 251_520..<651_520, keep: 300_000..<560_000),
            GigaAMChunker.Window(audio: 511_360..<700_000, keep: 560_000..<700_000),
        ]
        var centers: [Int] = []
        for (index, window) in windows.enumerated() {
            let total = (GigaAMFrontend.frameCount(samples: window.audio.count) + 3) / 4
            let kept = GigaAMChunker.keptSteps(of: window, total: total, isLast: index == windows.count - 1)
            for step in kept {
                let center = window.audio.lowerBound + step * 640 + 160
                XCTAssertTrue(index == windows.count - 1 || window.keep.contains(center), "окно \(index), кадр \(step)")
                centers.append(center)
            }
        }
        // Окна на общей сетке: центры идут ровно через 40 мс — без пропусков и повторов.
        for (a, b) in zip(centers, centers.dropFirst()) {
            XCTAssertEqual(b - a, 640)
        }
        XCTAssertLessThanOrEqual(centers.first!, 640)
        XCTAssertGreaterThanOrEqual(centers.last!, 700_000 - 1_280)
    }

    // MARK: - Декодер

    private let vocabulary: [String] = {
        var pieces = ["<unk>", "\u{2581}", ".", "\u{2581}При", "вет", ",", "\u{2581}мир", "\u{2581}к", "о", "т"]
        pieces += (pieces.count..<256).map { "x\($0)" }
        return pieces
    }()

    /// Логиты T × 257 с единицей там, где задан токен.
    private func logits(_ path: [Int]) -> [Float] {
        var values = [Float](repeating: -10, count: path.count * 257)
        for (t, token) in path.enumerated() { values[t * 257 + token] = 0 }
        return values
    }

    func testGreedyCollapsesRepeatsAndDropsBlank() {
        let blank = 256
        // «▁При вет вет , ▁мир .» с повторами и blank-ами между.
        let path = [blank, 3, 3, blank, 4, 4, blank, 5, blank, 6, 6, 6, 2, blank]
        let tokens = GigaAMDecoder.greedyTokens(logProbs: logits(path), steps: path.count, classes: 257, blank: blank)
        XCTAssertEqual(tokens, [3, 4, 5, 6, 2])
        XCTAssertEqual(GigaAMDecoder.text(tokens: tokens, vocabulary: vocabulary), "Привет, мир.")
    }

    /// Повтор, разделённый blank-ом, — две буквы («кот» → «к о о т» нельзя, а «о blank о» — «оо»).
    func testBlankSeparatesGenuineRepeats() {
        let blank = 256
        let path = [7, 8, blank, 8, 9]
        let tokens = GigaAMDecoder.greedyTokens(logProbs: logits(path), steps: path.count, classes: 257, blank: blank)
        XCTAssertEqual(tokens, [7, 8, 8, 9])
        XCTAssertEqual(GigaAMDecoder.text(tokens: tokens, vocabulary: vocabulary), "коот")
    }

    /// Кадры за пределами длины энкодера не читаются; `<unk>` и лишние пробелы не попадают в текст.
    func testRespectsValidStepsAndSkipsUnknown() {
        let blank = 256
        let path = [3, 0, 4, 1, 1, blank, 6, 2]
        let all = GigaAMDecoder.greedyTokens(logProbs: logits(path), steps: path.count, classes: 257, blank: blank)
        XCTAssertEqual(GigaAMDecoder.text(tokens: all, vocabulary: vocabulary), "Привет мир.")
        let cut = GigaAMDecoder.greedyTokens(logProbs: logits(path), steps: 3, classes: 257, blank: blank)
        XCTAssertEqual(GigaAMDecoder.text(tokens: cut, vocabulary: vocabulary), "Привет")
    }

    /// Склейка кадров двух окон: повтор на стыке схлопывается, как в одном проходе.
    func testCollapseAcrossStitchedWindows() {
        let blank = 256
        let first = [3, 3, blank, 4]
        let second = [4, blank, 6, 2]
        XCTAssertEqual(GigaAMDecoder.collapse(first + second, blank: blank), [3, 4, 6, 2])
    }

    func testVocabularyParsing() {
        XCTAssertEqual(GigaAMModelStore.parseVocabulary("<unk>\n\u{2581}\n.\n"), ["<unk>", "\u{2581}", "."])
        XCTAssertEqual(GigaAMModelStore.parseVocabulary("a\r\nb"), ["a", "b"])
    }

    // MARK: - Язык

    func testRejectsNonRussianWithoutTouchingModel() async {
        let engine = GigaAMEngine(store: GigaAMModelStore(directory: URL(fileURLWithPath: "/nonexistent/gigaam")))
        for language in [Language.uk, .en] {
            do {
                try await engine.prepare(language: language) { _ in }
                XCTFail("prepare должен отказать для \(language)")
            } catch let error as GigaAMError {
                guard case .unsupportedLanguage = error else { return XCTFail("\(error)") }
                XCTAssertNotNil(error.errorDescription)
            } catch {
                XCTFail("\(error)")
            }
            do {
                _ = try await engine.transcribe([0], language: language, prompt: "")
                XCTFail("transcribe должен отказать для \(language)")
            } catch {
                XCTAssertTrue(error is GigaAMError)
            }
        }
        do {
            _ = try await engine.transcribe([0], language: .ru, prompt: "", translating: true)
            XCTFail("перевод не поддерживается")
        } catch {
            guard case TranscriptionEngineError.translationUnsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(engine.isLoaded)
    }
}

/// Живая проба GigaAM на настоящей записи. Не часть обычного прогона: без
/// `CRIBE_GIGAAM_PROBE_WAV` пропускается — нужна модель на диске (~850 МБ с кэшем).
///
/// ```
/// CRIBE_GIGAAM_PROBE_WAV=запись.wav swift test --disable-keychain --filter GigaAMProbeTests
/// ```
final class GigaAMProbeTests: XCTestCase {
    func testTranscribesRealRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["CRIBE_GIGAAM_PROBE_WAV"] else {
            throw XCTSkip("CRIBE_GIGAAM_PROBE_WAV не задан")
        }
        let samples = try Self.samples(path)
        let engine = GigaAMEngine()
        let clock = Date()
        try await engine.prepare(language: .ru) { _ in }
        let prepared = Date().timeIntervalSince(clock)
        let pass = Date()
        let text = try await engine.transcribe(samples, language: .ru, prompt: "")
        FileHandle.standardError.write(Data(String(
            format: "PROBE: подготовка %.2f c, проход %.2f c\nPROBE:   %@\n",
            prepared, Date().timeIntervalSince(pass), text
        ).utf8))
        XCTAssertFalse(text.isEmpty)

        if ProcessInfo.processInfo.environment["CRIBE_GIGAAM_PROBE_FRAMES"] != nil {
            let runtime = try await GigaAMRuntime.load(from: .shared)
            let labels = try await runtime.labels(samples[0..<min(samples.count, GigaAMFrontend.windowSamples)])
            let line = labels.enumerated().compactMap { index, label in
                label == runtime.blank ? nil : "\(index):\(runtime.vocabulary[label])"
            }.joined(separator: " ")
            FileHandle.standardError.write(Data("PROBE: кадры \(line)\n".utf8))
        }

        engine.unload()
        XCTAssertFalse(engine.isLoaded)
    }

    /// WAV 16 кГц моно, 16 бит — как пишет приложение и `say --data-format=LEI16@16000`.
    private static func samples(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let range = data.range(of: Data("data".utf8)) else { throw XCTSkip("не WAV: \(path)") }
        let body = data[(range.upperBound + 4)...]
        return body.withUnsafeBytes { raw in
            (0..<raw.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
        }
    }
}
