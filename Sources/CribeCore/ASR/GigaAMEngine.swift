import Accelerate
import CoreML
import CryptoKit
import Foundation
import OSLog

/// Распознавание на Sber GigaAM v3 (вариант `v3_e2e_ctc`) через Core ML порт
/// `inhum/gigaam-v3-coreml` (MIT, Ivan Ushakov; исходная модель — salute-developers, MIT).
///
/// **Чем берёт.** Модель обучена только на русском, ставит пунктуацию и заглавные сама
/// (e2e-вариант), на Neural Engine проходит 25 с аудио за ~0,1 с.
///
/// **Чем платит.** Только русский. Английские слова почти всегда пишет кириллицей
/// («гитхаб») — латиницу возвращает второй/третий слой, как и у Parakeet.
///
/// **Чего не умеет.** Подсказки словарём (жадный CTC без языковой модели), перевода,
/// таймкодов. Вход модели — фиксированное окно лог-мел на 25 с: длиннее режем сами
/// (см. `GigaAMChunker`), лог-мел считаем сами (см. `GigaAMFrontend`), токены в текст
/// собираем сами (см. `GigaAMDecoder`) — в пакете Core ML только энкодер с CTC-головой.
public final class GigaAMEngine: TranscriptionEngine, @unchecked Sendable {
    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "GigaAM")

    /// Как модель называется в интерфейсе.
    public static let displayName = "GigaAM v3"

    /// Единственный язык модели.
    public static let supportedLanguage: Language = .ru

    /// Где лежит модель.
    ///
    /// Не в `Cribe/models`, хотя так было бы симметричнее: эту папку целиком считает
    /// и удаляет `LegacyWhisperCache` как «старые веса Whisper». GigaAM там попал бы
    /// в счёт «лишних гигабайт», и кнопка очистки снесла бы его вместе с Whisper.
    public static var modelDirectory: URL { GigaAMModelStore.shared.directory }

    /// Лежат ли файлы модели на диске (скачаны и сверены). Как у Parakeet: прогреву при
    /// запуске надо знать, не полезет ли `prepare` качать 420 МБ без спроса.
    public static var isInstalled: Bool { GigaAMModelStore.shared.isInstalled }

    private let store: GigaAMModelStore
    private let queue = DispatchQueue(label: "online.nazarovych.cribe.gigaam")
    private var runtime: GigaAMRuntime?
    private var loading: Task<GigaAMRuntime, Error>?
    private let progress = ProgressFanout()

    public init() {
        store = .shared
    }

    init(store: GigaAMModelStore) {
        self.store = store
    }

    public func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        try Self.check(language)
        if queue.sync(execute: { runtime }) != nil {
            onState(.ready)
            return
        }
        onState(store.isInstalled ? .loading : .downloading(0))
        do {
            _ = try await ready(onState: onState)
            onState(.ready)
        } catch {
            onState(.notLoaded)
            throw error
        }
    }

    /// Выгрузить модель из памяти (~0,5 ГБ). Файлы остаются на диске: следующий `prepare`
    /// или `transcribe` загрузит её заново без скачивания. Идущую загрузку не отменяет —
    /// её дождутся те, кто её ждёт, но движок результат не запомнит.
    public func unload() {
        queue.sync {
            runtime = nil
            loading = nil
        }
        Self.logger.notice("\(Self.displayName, privacy: .public) выгружен из памяти")
    }

    /// Загружена ли модель в память сейчас.
    public var isLoaded: Bool { queue.sync { runtime != nil } }

    /// Прогретая модель. Параллельные вызовы склеиваются в одну загрузку — как у Parakeet.
    private func ready(onState: (@Sendable (ASRModelState) -> Void)? = nil) async throws -> GigaAMRuntime {
        // Уже в памяти — прогресс не трогаем: им может пользоваться чужая загрузка.
        if let runtime = queue.sync(execute: { runtime }) { return runtime }
        let catchUp = progress.join(onState)
        let task: Task<GigaAMRuntime, Error> = queue.sync {
            if let runtime { return Task { runtime } }
            if let loading { return loading }
            let store = self.store
            let progress = self.progress
            let started = Task<GigaAMRuntime, Error> {
                if !store.isInstalled {
                    let clock = Date()
                    try await store.download { progress.send(.downloading($0)) }
                    Self.logger.notice("скачано за \(Date().timeIntervalSince(clock), format: .fixed(precision: 1)) с")
                }
                progress.send(.loading)
                let clock = Date()
                let runtime = try await GigaAMRuntime.load(from: store)
                Self.logger.notice(
                    "\(Self.displayName, privacy: .public) готов за \(Date().timeIntervalSince(clock), format: .fixed(precision: 1)) с"
                )
                return runtime
            }
            loading = started
            return started
        }
        if let catchUp { onState?(catchUp) }
        do {
            let runtime = try await task.value
            queue.sync {
                // `unload()` во время загрузки снял `loading` — тогда результат не храним.
                if loading == task { self.runtime = runtime; loading = nil }
            }
            progress.reset()
            return runtime
        } catch {
            queue.sync { if loading == task { loading = nil } }
            progress.reset()
            throw error
        }
    }

    public func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        // Промпт не передаётся: входа для него у CTC-модели нет, словарь применяет второй слой.
        try Self.check(language)
        let runtime = try await ready()
        // Кадры своих частей всех окон подряд — и один жадный проход по ним (см. `GigaAMChunker`).
        let windows = GigaAMChunker.windows(samples)
        var labels: [Int] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let steps = try await runtime.labels(samples[window.audio])
            let kept = GigaAMChunker.keptSteps(of: window, total: steps.count, isLast: index == windows.count - 1)
            labels += steps[kept]
        }
        let tokens = GigaAMDecoder.collapse(labels, blank: runtime.blank)
        return GigaAMDecoder.text(tokens: tokens, vocabulary: runtime.vocabulary)
    }

    public func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String {
        guard !translating else { throw TranscriptionEngineError.translationUnsupported }
        return try await transcribe(samples, language: language, prompt: prompt)
    }

    private static func check(_ language: Language) throws {
        guard language == supportedLanguage else { throw GigaAMError.unsupportedLanguage(language) }
    }
}

public enum GigaAMError: LocalizedError {
    case unsupportedLanguage(Language)
    case badDownload(file: String, reason: String)
    case badModelFiles(String)
    case badModelOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(language):
            return "\(GigaAMEngine.displayName) распознаёт только русский — для языка «\(language.displayName)» выберите Parakeet."
        case let .badDownload(file, reason):
            return "Не удалось скачать модель \(GigaAMEngine.displayName) (\(file)): \(reason)."
        case let .badModelFiles(reason):
            return "Файлы модели \(GigaAMEngine.displayName) повреждены: \(reason)."
        case let .badModelOutput(reason):
            return "Модель \(GigaAMEngine.displayName) вернула неожиданный ответ: \(reason)."
        }
    }
}

// MARK: - Модель в памяти

/// Загруженный Core ML пакет вместе со всем, что нужно вокруг него: фронтенд и словарь.
final class GigaAMRuntime: @unchecked Sendable {
    let model: MLModel
    let frontend: GigaAMFrontend
    let vocabulary: [String]
    private let featuresName: String
    private let lengthsName: String

    private init(model: MLModel, frontend: GigaAMFrontend, vocabulary: [String]) throws {
        self.model = model
        self.frontend = frontend
        self.vocabulary = vocabulary
        // Имена входов берём из описания модели, а не из README: так переживём
        // перевыпуск пакета с другими именами. Признак — ранг тензора.
        let inputs = model.modelDescription.inputDescriptionsByName
        func input(rank: Int) -> String? {
            inputs.first { $0.value.multiArrayConstraint?.shape.count == rank }?.key
        }
        guard let features = input(rank: 3), let lengths = input(rank: 1) else {
            throw GigaAMError.badModelFiles("у пакета нет входов [1,64,T] и [1]")
        }
        featuresName = features
        lengthsName = lengths
    }

    static func load(from store: GigaAMModelStore) async throws -> GigaAMRuntime {
        let tables = try store.loadTables()
        let frontend = try GigaAMFrontend(window: tables.window, filterbank: tables.filterbank)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let compiled = try await store.compiledModel()
        let model: MLModel
        do {
            model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        } catch {
            // Скомпилированный кэш мог устареть или побиться — пересобираем один раз
            // из исходного пакета, который ради этого и храним.
            GigaAMModelStore.logger.error("кэш .mlmodelc не загрузился (\(error.localizedDescription, privacy: .public)) — пересобираю")
            let rebuilt = try await store.compiledModel(forceRebuild: true)
            model = try await MLModel.load(contentsOf: rebuilt, configuration: configuration)
        }
        return try GigaAMRuntime(model: model, frontend: frontend, vocabulary: tables.vocabulary)
    }

    /// id пустого символа CTC — сразу за словарём.
    var blank: Int { vocabulary.count }

    /// Один проход окна не длиннее 25 с: argmax по каждому настоящему кадру энкодера
    /// (по 40 мс), без схлопывания — схлопывает вызывающий, уже по склеенным окнам.
    func labels(_ samples: ArraySlice<Float>) async throws -> [Int] {
        guard samples.count <= GigaAMFrontend.windowSamples else {
            throw GigaAMError.badModelOutput("окно на \(samples.count) отсчётов длиннее 25 с")
        }
        let realFrames = GigaAMFrontend.frameCount(samples: samples.count)
        guard realFrames > 0 else { return [] }

        let features = frontend.logMel(samples, paddedTo: GigaAMFrontend.windowSamples)
        let frames = GigaAMFrontend.windowFrames
        let input = try MLMultiArray(shape: [1, NSNumber(value: GigaAMFrontend.mels), NSNumber(value: frames)], dataType: .float32)
        try Self.fill(input, with: features)
        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: Int32(realFrames))

        let output = try await model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
                featuresName: MLFeatureValue(multiArray: input),
                lengthsName: MLFeatureValue(multiArray: lengths),
            ])
        )
        // Имена выходов — служебные имена конвертера («_to_copy_6»); различаем по рангу.
        var logits: MLMultiArray?
        var encoded: Int?
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue else { continue }
            if array.shape.count == 3 {
                logits = array
            } else if array.count == 1 {
                encoded = array[0].intValue
            }
        }
        guard let logits else { throw GigaAMError.badModelOutput("нет тензора логитов") }
        let (values, steps, classes) = try Self.floats(logits)
        guard classes == vocabulary.count + 1 else {
            throw GigaAMError.badModelOutput("классов \(classes), а словарь на \(vocabulary.count) + blank")
        }
        // Энкодер прореживает кадры в 4 раза; длину отдаёт сам. Нет её — считаем по кадрам.
        let valid = min(steps, max(0, encoded ?? (realFrames + 3) / 4))
        return GigaAMDecoder.labels(logProbs: values, steps: valid, classes: classes)
    }

    /// Признаки [64 × T] построчно — в тензор [1, 64, T] с учётом его шагов.
    private static func fill(_ array: MLMultiArray, with features: [Float]) throws {
        let mels = GigaAMFrontend.mels
        let frames = GigaAMFrontend.windowFrames
        guard features.count == mels * frames else {
            throw GigaAMError.badModelOutput("признаков \(features.count), ждали \(mels * frames)")
        }
        let melStride = array.strides[1].intValue
        let frameStride = array.strides[2].intValue
        array.withUnsafeMutableBytes { raw, _ in
            let out = raw.bindMemory(to: Float.self)
            features.withUnsafeBufferPointer { src in
                for m in 0..<mels {
                    let row = src.baseAddress! + m * frames
                    if frameStride == 1 {
                        (out.baseAddress! + m * melStride).update(from: row, count: frames)
                    } else {
                        for t in 0..<frames { out[m * melStride + t * frameStride] = row[t] }
                    }
                }
            }
        }
    }

    /// Логиты [1, T, C] → плотный Float-массив T × C. Выход ANE бывает в fp16 и с
    /// выровненными строками, поэтому идём по шагам тензора, а не по `count`.
    private static func floats(_ array: MLMultiArray) throws -> ([Float], Int, Int) {
        let steps = array.shape[1].intValue
        let classes = array.shape[2].intValue
        let rowStride = array.strides[1].intValue
        let colStride = array.strides[2].intValue
        var result = [Float](repeating: 0, count: steps * classes)
        let dataType = array.dataType
        try array.withUnsafeBytes { raw in
            switch dataType {
            case .float32:
                let src = raw.bindMemory(to: Float.self)
                for t in 0..<steps {
                    for c in 0..<classes { result[t * classes + c] = src[t * rowStride + c * colStride] }
                }
            case .float16:
                let src = raw.bindMemory(to: UInt16.self)
                var row = [UInt16](repeating: 0, count: classes)
                for t in 0..<steps {
                    for c in 0..<classes { row[c] = src[t * rowStride + c * colStride] }
                    row.withUnsafeMutableBufferPointer { half in
                        result.withUnsafeMutableBufferPointer { full in
                            var source = vImage_Buffer(
                                data: half.baseAddress, height: 1, width: vImagePixelCount(classes), rowBytes: classes * 2
                            )
                            var destination = vImage_Buffer(
                                data: full.baseAddress! + t * classes, height: 1,
                                width: vImagePixelCount(classes), rowBytes: classes * 4
                            )
                            vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
                        }
                    }
                }
            case .double:
                let src = raw.bindMemory(to: Double.self)
                for t in 0..<steps {
                    for c in 0..<classes { result[t * classes + c] = Float(src[t * rowStride + c * colStride]) }
                }
            default:
                throw GigaAMError.badModelOutput("тип логитов \(dataType.rawValue)")
            }
        }
        return (result, steps, classes)
    }
}

// MARK: - Лог-мел фронтенд

/// Лог-мел признаки ровно как у препроцессора GigaAM v3.
///
/// Параметры — из конфига самого чекпойнта (`ai-sage/GigaAM-v3`, ветка `e2e_ctc`,
/// `config.json → preprocessor`) и `gigaam/preprocess.py`: 16 кГц, `n_fft = win_length = 320`,
/// `hop_length = 160`, `center = false`, 64 мела (HTK, без нормировки), мощность (|X|²),
/// затем `log(clamp(x, 1e-9, 1e9))`. Кадров `(N − 320) / 160 + 1`. Никакой нормировки
/// признаков после логарифма нет.
///
/// Окно и мел-банк не вычисляем, а берём из пакета (`gigaam-window.f32`,
/// `gigaam-melfb.f32`): это буферы самого чекпойнта, которыми он при загрузке перекрывает
/// torchaudio-шные. Сверка 2026-11-19: окно — периодический Ханн, мел-банк — стандартный
/// HTK-банк torchaudio, оба округлены до bfloat16 (расхождение с формулой до 0,002 —
/// ровно шаг bf16). Раскладка банка в файле — [161 частота × 64 мела], как `fb` в
/// torchaudio (README пакета пишет «64 × 161» — это неверно, см. `checkLayout`).
final class GigaAMFrontend: @unchecked Sendable {
    static let sampleRate = 16_000
    static let fftSize = 320
    static let hop = 160
    static let bins = fftSize / 2 + 1 // 161
    static let mels = 64
    /// Окно модели: 25 с — ровно `LONGFORM_THRESHOLD` исходного `transcribe` GigaAM.
    static let windowSamples = 25 * sampleRate
    static let windowFrames = frameCount(samples: windowSamples) // 2499
    static let logFloor: Float = 1e-9
    static let logCeiling: Float = 1e9

    let window: [Float]
    /// [bins × mels] построчно.
    let filterbank: [Float]
    private let setup: OpaquePointer

    init(window: [Float], filterbank: [Float]) throws {
        guard window.count == Self.fftSize else {
            throw GigaAMError.badModelFiles("окно на \(window.count) отсчётов вместо \(Self.fftSize)")
        }
        guard filterbank.count == Self.bins * Self.mels else {
            throw GigaAMError.badModelFiles("мел-банк на \(filterbank.count) чисел вместо \(Self.bins * Self.mels)")
        }
        try Self.checkLayout(filterbank)
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD) else {
            throw GigaAMError.badModelFiles("vDSP не создал DFT на \(Self.fftSize)")
        }
        self.window = window
        self.filterbank = filterbank
        self.setup = setup
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    static func frameCount(samples: Int) -> Int {
        samples < fftSize ? 0 : (samples - fftSize) / hop + 1
    }

    /// Раскладка [частота × мел]: пик каждого мел-фильтра должен идти по частоте
    /// неубывающе. В транспонированной раскладке пики скачут — тогда лучше упасть,
    /// чем молча кормить модель мусором.
    static func checkLayout(_ filterbank: [Float]) throws {
        var previous = -1
        for m in 0..<mels {
            var best = 0
            var bestValue: Float = 0
            for k in 0..<bins where filterbank[k * mels + m] > bestValue {
                bestValue = filterbank[k * mels + m]
                best = k
            }
            guard bestValue > 0, best >= previous else {
                throw GigaAMError.badModelFiles("мел-банк не в раскладке [161 × 64]")
            }
            previous = best
        }
    }

    /// Лог-мел [mels × frames] построчно (как вход модели [1, 64, T]). Аудио дополняется
    /// нулями до `paddedTo` отсчётов — так делает и README пакета: модель видит тишину
    /// в хвосте, а настоящую длину узнаёт из `feature_lengths`.
    func logMel(_ samples: ArraySlice<Float>, paddedTo padded: Int? = nil) -> [Float] {
        var audio = [Float](samples)
        if let padded, audio.count < padded {
            audio.append(contentsOf: repeatElement(0, count: padded - audio.count))
        }
        let frames = Self.frameCount(samples: audio.count)
        guard frames > 0 else { return [] }

        // Мощность построчно по кадрам: [frames × bins].
        var power = [Float](repeating: 0, count: frames * Self.bins)
        audio.withUnsafeBufferPointer { src in
            power.withUnsafeMutableBufferPointer { dst in
                for t in 0..<frames {
                    powerSpectrum(src.baseAddress! + t * Self.hop, into: dst.baseAddress! + t * Self.bins)
                }
            }
        }

        // [frames × bins] · [bins × mels] = [frames × mels], затем транспонируем в [mels × frames].
        var melByFrame = [Float](repeating: 0, count: frames * Self.mels)
        vDSP_mmul(power, 1, filterbank, 1, &melByFrame, 1,
                  vDSP_Length(frames), vDSP_Length(Self.mels), vDSP_Length(Self.bins))
        var result = [Float](repeating: 0, count: frames * Self.mels)
        vDSP_mtrans(melByFrame, 1, &result, 1, vDSP_Length(Self.mels), vDSP_Length(frames))

        var low = Self.logFloor
        var high = Self.logCeiling
        var count = Int32(result.count)
        result.withUnsafeMutableBufferPointer { buffer in
            let values = buffer.baseAddress!
            vDSP_vclip(values, 1, &low, &high, values, 1, vDSP_Length(buffer.count))
            vvlogf(values, values, &count)
        }
        return result
    }

    /// |X[k]|² одного кадра из 320 отсчётов, k = 0…160.
    func powerSpectrum(_ frame: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        let half = Self.fftSize / 2
        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
        var evenIn = [Float](repeating: 0, count: half)
        var oddIn = [Float](repeating: 0, count: half)
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        // Вещественный DFT в vDSP берёт сигнал упакованным: чётные отсчёты — в «real»,
        // нечётные — в «imag».
        evenIn.withUnsafeMutableBufferPointer { even in
            oddIn.withUnsafeMutableBufferPointer { odd in
                var split = DSPSplitComplex(realp: even.baseAddress!, imagp: odd.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
            }
        }
        vDSP_DFT_Execute(setup, evenIn, oddIn, &re, &im)
        // Результат vDSP вдвое больше математического DFT, а в im[0] лежит Найквист:
        // re[0] = 2·X[0], im[0] = 2·X[160], (re[k], im[k]) = 2·X[k].
        out[0] = re[0] * re[0] / 4
        out[half] = im[0] * im[0] / 4
        for k in 1..<half {
            out[k] = (re[k] * re[k] + im[k] * im[k]) / 4
        }
    }

    /// Удобная обёртка для тестов.
    func powerSpectrum(_ frame: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: Self.bins)
        frame.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in powerSpectrum(src.baseAddress!, into: dst.baseAddress!) }
        }
        return out
    }
}

// MARK: - Нарезка на окна

/// Нарезка записи длиннее 25 с на окна модели: окна перекрываются, но текст на стыке
/// не склеивается — склеиваются кадры CTC.
///
/// **Почему не просто резать по тишине.** Первая версия резала встык в самом тихом месте.
/// На записях владельца e2e-модель на каждом стыке вела себя как в конце и начале фразы:
/// ставила точку и заглавную посреди предложения («И, возможно. Тут же…», «могу Одну
/// задачу»). Модели нужен контекст по обе стороны разреза.
///
/// **Почему не склеивать текст двух перекрытых окон.** Тогда пришлось бы искать, какие
/// слова оба окна услышали дважды, — у жадного CTC без таймкодов это угадайка, и ошибка
/// стоит дубля или потери слова.
///
/// **Как сделано.** Выход CTC привязан ко времени: кадр энкодера — 40 мс (640 отсчётов).
/// Каждое окно — до 25 с аудио; у него есть «своя» часть (`keep`) и контекст по краям —
/// 3 с слева (кроме первого окна) и всё, что влезает справа. Берём из окна только кадры
/// своей части, кадры всех окон ставим подряд и уже их схлопываем жадным CTC как один
/// проход. Окна начинаются на общей сетке кадров, так что кадры стыкуются без дублей. Границу своей части кладём в самое тихое место (энергия, сглаженная окном
/// 300 мс — короче смычки согласного не спутаем с паузой): там кадры — blank в обоих
/// окнах, и сдвиг сетки кадров между окнами на стыке ничего не дублирует и не теряет.
/// Если пауз нет совсем, граница всё равно встанет в самое тихое место; благодаря
/// контексту модель и там слышит слово целиком.
enum GigaAMChunker {
    struct Window: Equatable {
        /// Что подаётся модели (не длиннее 25 с).
        let audio: Range<Int>
        /// Чьи кадры берём из этого окна. Части всех окон покрывают запись встык.
        let keep: Range<Int>
    }

    static let windowLength = GigaAMFrontend.windowSamples
    static let leftContext = 3 * GigaAMFrontend.sampleRate
    static let rightContext = 3 * GigaAMFrontend.sampleRate
    /// Своя часть не короче 9 с: граница ищется в оставшихся ~10 с.
    static let minKeep = 9 * GigaAMFrontend.sampleRate
    static let hop = 160 // 10 мс
    static let smoothing = 30 // кадров по 10 мс

    static func windows(_ samples: [Float]) -> [Window] {
        let count = samples.count
        guard count > 0 else { return [] }
        var result: [Window] = []
        var keepStart = 0
        while true {
            // Начало окна — на сетке кадров энкодера (кратно 640): тогда у всех окон
            // одна и та же сетка, и каждый кадр записи достаётся ровно одному окну.
            let start = max(0, (keepStart - leftContext) / samplesPerStep * samplesPerStep)
            if count - start <= windowLength {
                result.append(Window(audio: start..<count, keep: keepStart..<count))
                return result
            }
            let end = start + windowLength
            let cut = quietestPoint(samples, from: keepStart + minKeep, to: end - rightContext)
            result.append(Window(audio: start..<end, keep: keepStart..<cut))
            keepStart = cut
        }
    }

    /// Самое тихое место в [from, to]: середина 300-мс окна с наименьшей энергией.
    static func quietestPoint(_ samples: [Float], from: Int, to: Int) -> Int {
        let frames = (to - from) / hop
        guard frames > smoothing else { return to }
        var energy = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { buffer in
            for j in 0..<frames {
                vDSP_svesq(buffer.baseAddress! + from + j * hop, 1, &energy[j], vDSP_Length(hop))
            }
        }
        var window = energy[0..<smoothing].reduce(0, +)
        var best = window
        var bestStart = 0
        for j in 1...(frames - smoothing) {
            window += energy[j + smoothing - 1] - energy[j - 1]
            // `<=`: при равной тишине берём позднее место — своя часть длиннее, окон меньше.
            if window <= best {
                best = window
                bestStart = j
            }
        }
        return min(to, from + (bestStart + smoothing / 2) * hop)
    }

    /// Отсчётов на кадр энкодера: шаг признаков 160 × прореживание 4.
    static let samplesPerStep = GigaAMFrontend.hop * 4
    /// Центр кадра энкодера j — около 640·j + 160 отсчётов от начала окна (центр первого
    /// кадра признаков, свёртки прореживания симметричные).
    static let stepCenter = GigaAMFrontend.hop

    /// Какие кадры выхода окна относятся к его своей части: те, чей центр в `keep`.
    /// У последнего окна — все кадры до конца.
    static func keptSteps(of window: Window, total steps: Int, isLast: Bool) -> Range<Int> {
        func step(at sample: Int) -> Int {
            let offset = sample - window.audio.lowerBound - stepCenter
            return max(0, (offset + samplesPerStep - 1) / samplesPerStep)
        }
        let first = min(steps, step(at: window.keep.lowerBound))
        let last = isLast ? steps : min(steps, step(at: window.keep.upperBound))
        return first..<max(first, last)
    }
}

// MARK: - Декодер

/// Жадный CTC: argmax по кадру → схлопнуть повторы → убрать blank. Так же, как
/// `CTCGreedyDecoding` в исходном коде GigaAM (повтор сбрасывается blank-ом: «а, blank, а»
/// — две буквы).
enum GigaAMDecoder {
    static let unknown = 0
    static let boundary: Character = "\u{2581}" // ▁ — начало слова в sentencepiece

    static func greedyTokens(logProbs: [Float], steps: Int, classes: Int, blank: Int) -> [Int] {
        collapse(labels(logProbs: logProbs, steps: steps, classes: classes), blank: blank)
    }

    /// Лучший класс каждого кадра.
    static func labels(logProbs: [Float], steps: Int, classes: Int) -> [Int] {
        precondition(logProbs.count >= steps * classes)
        var labels = [Int](repeating: 0, count: steps)
        logProbs.withUnsafeBufferPointer { buffer in
            for t in 0..<steps {
                var value: Float = 0
                var index: vDSP_Length = 0
                vDSP_maxvi(buffer.baseAddress! + t * classes, 1, &value, &index, vDSP_Length(classes))
                labels[t] = Int(index)
            }
        }
        return labels
    }

    /// Схлопнуть повторы и убрать blank.
    static func collapse(_ labels: [Int], blank: Int) -> [Int] {
        var tokens: [Int] = []
        var previous = -1
        for label in labels {
            if label != blank, label != previous { tokens.append(label) }
            previous = label
        }
        return tokens
    }

    /// Куски sentencepiece в текст: `▁` — пробел перед словом. Пунктуацию и заглавные
    /// e2e-модель выдаёт отдельными кусками («,», «.», «?», «▁В»), их просто склеиваем.
    /// `<unk>` пропускаем — sentencepiece вставил бы на его место « ⁇ ».
    static func text(tokens: [Int], vocabulary: [String]) -> String {
        var raw = ""
        for token in tokens where token != unknown && token < vocabulary.count {
            raw += vocabulary[token]
        }
        let spaced = raw.replacingOccurrences(of: String(boundary), with: " ")
        return spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

// MARK: - Файлы модели

/// Скачивание, сверка и компиляция пакета. Ревизия на Hugging Face закреплена коммитом,
/// а файлы — размером и SHA-256: перевыпуск репозитория не подменит модель молча.
final class GigaAMModelStore: @unchecked Sendable {
    static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "GigaAM")

    static let shared = GigaAMModelStore(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cribe", isDirectory: true)
            .appendingPathComponent("gigaam-v3", isDirectory: true)
    )

    static let repository = "inhum/gigaam-v3-coreml"
    static let revision = "43dc96918bc232deafa7b7d0600fb499806f7ac1"
    static let packageName = "gigaam_v3_e2e.mlpackage"
    static let compiledName = "gigaam_v3_e2e.mlmodelc"
    static let windowFile = "gigaam-window.f32"
    static let filterbankFile = "gigaam-melfb.f32"
    static let vocabularyFile = "gigaam-vocab.txt"

    struct File {
        let path: String
        let size: Int64
        let sha256: String
    }

    static let files: [File] = [
        File(path: "\(packageName)/Manifest.json", size: 617,
             sha256: "cd7840db2ffe56befcbb3e324dc661846ac5706c4a8c3725be56ff67b37e2eb2"),
        File(path: "\(packageName)/Data/com.apple.CoreML/model.mlmodel", size: 469_254,
             sha256: "8e0c43329503b3b2fc41f6e594f44d7b35acdd0bd61a91bf5741557d716be957"),
        File(path: "\(packageName)/Data/com.apple.CoreML/weights/weight.bin", size: 441_914_178,
             sha256: "706153a1e14e2b26f328f394f3eded2689865eaf2d653c021006a4f3ab3a0ec6"),
        File(path: windowFile, size: 1_280,
             sha256: "834a6744851a775dbb1831e9e17f0f702599b4d52c1d97d7638b3f170824419f"),
        File(path: filterbankFile, size: 41_216,
             sha256: "e87260b36046d4384ea4e7ca82ff7e5a82b4f85381c34b16ccfa79c0803ffba2"),
        File(path: vocabularyFile, size: 1_083,
             sha256: "a5aac1a2913150f1e5400cfca1765406c01d0792c5842e3a1deea85bc8dfbc09"),
    ]

    let directory: URL
    private var staging: URL {
        directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".partial", isDirectory: true)
    }
    private var compiled: URL { directory.appendingPathComponent(Self.compiledName, isDirectory: true) }

    init(directory: URL) {
        self.directory = directory
    }

    /// Все файлы на месте и нужного размера. Хэш сверяется при скачивании, а не на каждом
    /// запуске: 420 МБ через SHA-256 — это секунда на каждый прогрев.
    var isInstalled: Bool {
        Self.files.allSatisfy { Self.size(of: directory.appendingPathComponent($0.path)) == $0.size }
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Качает в соседнюю папку `.partial` и только целиком сверенную переносит на место:
    /// оборванная загрузка не выглядит установленной моделью. Уже сверенные файлы из
    /// прошлой попытки не качаются заново.
    func download(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = Self.files.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        let downloader = GigaAMDownloader()
        defer { downloader.finish() }
        for file in Self.files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            if Self.size(of: destination) == file.size, (try? Self.sha256(of: destination)) == file.sha256 {
                done += file.size
                onProgress(Double(done) / Double(total))
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            let base = done
            try await downloader.download(Self.url(for: file.path), to: destination) { written in
                onProgress(Double(base + min(written, file.size)) / Double(total))
            }
            let hash = try Self.sha256(of: destination)
            guard Self.size(of: destination) == file.size, hash == file.sha256 else {
                try? fm.removeItem(at: destination)
                throw GigaAMError.badDownload(file: file.path, reason: "контрольная сумма не сошлась")
            }
            done += file.size
            onProgress(Double(done) / Double(total))
        }
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        try fm.moveItem(at: staging, to: directory)
    }

    static func url(for path: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/")!.appendingPathComponent(path)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Скомпилированная модель. `.mlpackage` компилируется один раз и кэшируется рядом
    /// как `.mlmodelc`; сам пакет храним — из него пересобираем кэш, если тот не загрузится.
    func compiledModel(forceRebuild: Bool = false) async throws -> URL {
        let fm = FileManager.default
        if forceRebuild { try? fm.removeItem(at: compiled) }
        if fm.fileExists(atPath: compiled.appendingPathComponent("coremldata.bin").path) {
            return compiled
        }
        let clock = Date()
        let temporary = try await MLModel.compileModel(at: directory.appendingPathComponent(Self.packageName))
        try? fm.removeItem(at: compiled)
        try fm.moveItem(at: temporary, to: compiled)
        Self.logger.notice("пакет скомпилирован за \(Date().timeIntervalSince(clock), format: .fixed(precision: 1)) с")
        return compiled
    }

    struct Tables {
        let window: [Float]
        let filterbank: [Float]
        let vocabulary: [String]
    }

    func loadTables() throws -> Tables {
        func floats(_ name: String) throws -> [Float] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard data.count % 4 == 0 else { throw GigaAMError.badModelFiles("\(name): длина не кратна 4") }
            return data.withUnsafeBytes { raw in
                (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
        }
        let text = try String(contentsOf: directory.appendingPathComponent(Self.vocabularyFile), encoding: .utf8)
        let vocabulary = Self.parseVocabulary(text)
        guard vocabulary.count == 256 else {
            throw GigaAMError.badModelFiles("в словаре \(vocabulary.count) кусков вместо 256")
        }
        return Tables(window: try floats(Self.windowFile), filterbank: try floats(Self.filterbankFile), vocabulary: vocabulary)
    }

    /// Один кусок на строку, номер строки — id. Пустую строку в конце файла не считаем.
    static func parseVocabulary(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}

/// Скачивание с долей прогресса. Async-`download(from:)` у URLSession долей не отдаёт,
/// поэтому — свой делегат. Файлы идут по одному: модель — один большой файл и пять мелких.
private final class GigaAMDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession!
    private var destination: URL?
    private var onWritten: (@Sendable (Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL, to destination: URL, onWritten: @escaping @Sendable (Int64) -> Void) async throws {
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.destination = destination
                self.onWritten = onWritten
                self.continuation = continuation
                self.moveError = nil
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Сессия держит делегата сильной ссылкой — без этого объект не освободится.
    func finish() {
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let callback = onWritten
        lock.unlock()
        callback?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Временный файл живёт только до выхода из этого метода — переносим сразу.
        lock.lock()
        let destination = self.destination
        lock.unlock()
        var failure: Error?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = GigaAMError.badDownload(file: downloadTask.originalRequest?.url?.lastPathComponent ?? "?",
                                              reason: "HTTP \(http.statusCode)")
        } else if let destination {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        lock.lock()
        moveError = failure
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        let failure = error ?? moveError
        self.continuation = nil
        lock.unlock()
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
