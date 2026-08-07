import Foundation
import OSLog
import WhisperKit

/// WhisperKit-движок: держит по одному прогретому инстансу на язык плюс отдельный
/// лёгкий инстанс (whisper-tiny) для live-превью.
/// Кэш и список идущих загрузок сериализованы через DispatchQueue, параллельные
/// `prepare` одного языка склеиваются в одну загрузку — второй раз многогигабайтная
/// модель не качается.
public final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    /// Скачивание одного варианта в папку моделей. Отдельная точка — ради тестов: склейку
    /// параллельных загрузок надо проверять без похода в сеть. В бою здесь `WhisperKit.download`.
    typealias VariantDownload = @Sendable (
        _ variant: String,
        _ onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Void

    /// Модель live-превью: multilingual tiny (~75 МБ) — качество черновое, зато проход
    /// идёт десятки миллисекунд вместо ~1.3 c у большой модели сессии.
    private static let previewVariant = "openai_whisper-tiny"

    /// Модели на диске: путь, «скачана ли», размер, удаление.
    private let store: ModelStore
    /// Подменяется только в тестах и только до первого вызова.
    var downloadVariant: VariantDownload

    private let queue = DispatchQueue(label: "online.nazarovych.cribe.whisper")
    /// Ключ — вариант модели, а не язык: русский и украинский могут делить один вариант,
    /// и грузить его дважды незачем.
    private var pipelines: [String: WhisperKit] = [:]
    /// Идущие загрузки. Результат кладётся в `pipelines`, поэтому Task<Void, Error>:
    /// WhisperKit не Sendable и не может быть значением задачи.
    private var loading: [String: Task<Void, Error>] = [:]
    /// Идущие скачивания без прогрева (кнопка «Скачать»). Отдельно от `loading`: успех такой
    /// задачи означает «файлы на диске», а не «модель прогрета», и присоединившийся `prepare`
    /// после неё обязан ещё прогреться.
    private var downloading: [String: Task<Void, Error>] = [:]
    /// Отдельный инстанс превью и его загрузка — тот же приём, но ключ один на всё приложение:
    /// tiny мультиязычная, язык форсируется в опциях декодирования.
    private var previewPipeline: WhisperKit?
    private var previewLoading: Task<Void, Error>?

    public init(store: ModelStore = .shared) {
        self.store = store
        downloadVariant = { variant, onProgress in
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: store.base,
                progressCallback: { progress in onProgress(progress.fractionCompleted) }
            )
        }
    }

    public func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        try await prepare(variant: language.whisperModel, language: language, onState: onState)
    }

    /// Скачана ли модель этого языка. Нужно прогреву при запуске: греть нечего, пока
    /// файлов нет, а `prepare` в этом случае полез бы их качать — полтора гигабайта
    /// в фоне, о которых никто не просил.
    public func isInstalled(for language: Language) -> Bool {
        store.isInstalled(variant: language.whisperModel)
    }

    /// Вариант модели названа явно: язык её больше не выбирает. Нужно повторному разбору
    /// записи — там русскую диктовку можно попросить разобрать на large-v3.
    public func prepare(
        variant: String,
        language: Language,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws {
        let pending: (task: Task<Void, Error>, joined: Bool)? = queue.sync {
            if pipelines[variant] != nil { return nil }
            if let inflight = loading[variant] { return (inflight, true) }
            // Тот же вариант уже качается по кнопке «Скачать» — дожидаемся файлов вместо
            // второго захода в сеть, а прогреваемся уже сами. Но ждать есть смысл, только
            // пока файлов нет: задача скачивания может не завершиться и после того, как
            // модель целиком легла на диск, и тогда ожидание становится вечным — диктовка
            // висит на «Загружаю модель…», ничего при этом не делая.
            let started = loadTask(
                variant: variant,
                onState: onState,
                after: pendingDownload(forVariant: variant)
            )
            loading[variant] = started
            return (started, false)
        }

        // Модель уже готова — повторный prepare ничего не делает.
        guard let pending else {
            onState(.ready)
            return
        }

        // Прогресс скачивания получает тот, кто загрузку начал; присоединившийся — только итог.
        if pending.joined { onState(.loading) }

        do {
            try await pending.task.value
            onState(.ready)
        } catch {
            onState(.notLoaded)
            throw error
        }
    }

    /// Кладёт модель языка на диск, не прогревая её: кнопка «Скачать» не должна тащить
    /// несколько гигабайт в оперативную память — прогрев сделает первая диктовка.
    /// Модель уже на диске — вызов ничего не делает. К идущей загрузке того же варианта
    /// присоединяемся: второй раз те же гигабайты не качаем. Отмена вызывающей задачи
    /// обрывает скачивание (`CancellationError`), но только своё: чужую ведёт `prepare`
    /// идущей диктовки — ей и прогресс, и право её обрывать.
    public func download(language: Language, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let variant = language.whisperModel
        guard !store.isInstalled(variant: variant) else { return }

        let pending: (task: Task<Void, Error>, owned: Bool) = queue.sync {
            if let inflight = downloading[variant] ?? loading[variant] { return (inflight, false) }
            let started = downloadTask(variant: variant, onProgress: onProgress)
            downloading[variant] = started
            return (started, true)
        }

        try await withTaskCancellationHandler {
            try await pending.task.value
        } onCancel: {
            if pending.owned { pending.task.cancel() }
        }
    }

    /// Убирает прогретую модель языка из памяти. Нужна перед удалением модели с диска:
    /// стирать файлы под живым инстансом нельзя. Модель не прогрета — вызов ничего не делает.
    public func unload(language: Language) {
        queue.sync { pipelines[language.whisperModel] = nil }
    }

    public func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        try await transcribe(samples, language: language, variant: language.whisperModel, prompt: prompt)
    }

    public func transcribe(
        _ samples: [Float],
        language: Language,
        variant: String,
        prompt: String
    ) async throws -> String {
        Self.text(of: try await run(samples, language: language, variant: variant, prompt: prompt))
    }

    /// Те же опции, что и у `transcribe` (они считаются в одном месте — `run`), другой разбор
    /// результата. Таймкоды сегментов абсолютны относительно переданного буфера: при
    /// VAD-нарезке WhisperKit сам сдвигает их на смещение чанка.
    public func transcribeSegments(
        _ samples: [Float],
        language: Language,
        prompt: String
    ) async throws -> [ASRSegment] {
        try await run(samples, language: language, prompt: prompt)
            .flatMap(\.segments)
            .sorted { $0.start < $1.start }
            .map {
                ASRSegment(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: Double($0.start),
                    end: Double($0.end)
                )
            }
    }

    public func preparePreview() async throws {
        let pending: Task<Void, Error>? = queue.sync {
            if previewPipeline != nil { return nil }
            if let inflight = previewLoading { return inflight }
            let started = previewLoadTask()
            previewLoading = started
            return started
        }
        // Модель уже готова — повторный вызов ничего не делает.
        guard let pending else { return }
        try await pending.value
    }

    public func transcribePreview(_ samples: [Float], language: Language) async throws -> String {
        guard let pipe = queue.sync(execute: { previewPipeline }) else {
            throw TranscriptionEngineError.previewNotPrepared
        }

        // Без промпта: биасинг словарём стоит токенов декодера, а превью — черновик,
        // латиницу гарантирует слой 2 на финале.
        // `windowClipTime: 0` — единственное отличие от опций финала. По умолчанию это 1 c,
        // которую WhisperKit срезает с конца окна против галлюцинаций, а вместе с ней
        // выбрасывает целиком любую запись короче секунды: `while seek < seekClipEnd - windowPadding`
        // не выполняется ни разу и превью возвращается пустым (замерено). Для черновика
        // защита не нужна — финальный проход считает те же опции, что и раньше.
        let options = DecodingOptions(
            task: .transcribe,
            language: language.rawValue,
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            windowClipTime: 0,
            chunkingStrategy: .vad
        )

        return Self.text(of: try await pipe.transcribe(audioArray: samples, decodeOptions: options))
    }

    // MARK: - Private

    /// Один проход большой модели. Опции здесь ровно одни на все проходы сессии —
    /// иначе фоновые проходы и финал распознавали бы по-разному, и склеивать их было бы нечем.
    private func run(
        _ samples: [Float],
        language: Language,
        variant: String? = nil,
        prompt: String
    ) async throws -> [TranscriptionResult] {
        let cached = queue.sync { pipelines[variant ?? language.whisperModel] }
        guard let pipe = cached else {
            throw TranscriptionEngineError.notPrepared(language)
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: language.rawValue,
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            promptTokens: promptTokens(prompt, pipe: pipe),
            chunkingStrategy: .vad
        )

        return try await pipe.transcribe(audioArray: samples, decodeOptions: options)
    }

    private static func text(of results: [TranscriptionResult]) -> String {
        results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Одна загрузка на вариант модели: скачивание (только если моделей ещё нет на диске) + прогрев.
    /// Сама кладёт результат в кэш и снимает себя со списка идущих — и при успехе, и при ошибке.
    /// `after` — идущее скачивание того же варианта, если оно есть.
    private func loadTask(
        variant: String,
        onState: @escaping @Sendable (ASRModelState) -> Void,
        after download: Task<Void, Error>?
    ) -> Task<Void, Error> {
        Task {
            do {
                // Ошибка или отмена чужого скачивания нам не мешает: `loadPipeline` увидит,
                // что файлов на диске нет, и скачает сам. По той же причине ожидание
                // ограничено по времени: подвисшая чужая задача не должна останавливать
                // диктовку навсегда — лучше сходить в сеть второй раз, чем не начать вовсе.
                if let download {
                    Self.logger.notice("Жду чужое скачивание \(variant, privacy: .public)")
                    let waited = await Self.wait(for: download, upTo: Self.downloadWaitLimit)
                    Self.logger.notice(
                        "Ожидание кончилось за \(waited, format: .fixed(precision: 1)) с"
                    )
                }
                let started = Date()
                Self.logger.notice("Прогреваю \(variant, privacy: .public)")
                let pipe = try await Self.loadPipeline(variant: variant, store: store, onState: onState)
                Self.logger.notice(
                    """
                    Прогрет \(variant, privacy: .public) за \
                    \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) с
                    """
                )
                self.queue.sync {
                    self.pipelines[variant] = pipe
                    self.loading[variant] = nil
                }
            } catch {
                // Ничего не кэшируем — следующий prepare попробует снова.
                self.queue.sync { self.loading[variant] = nil }
                throw error
            }
        }
    }

    /// Сколько ждать чужую загрузку, прежде чем идти за моделью самим.
    private static let downloadWaitLimit: Duration = .seconds(60)

    /// Подготовка модели — единственное место, где приложение молча стоит минуты. Стадии
    /// пишем в журнал: без них зависание пришлось бы выяснять по нулевому CPU и открытым
    /// файлам, как это однажды и случилось.
    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Model")

    /// Идущая загрузка, которую есть смысл дождаться перед прогревом, — и только она.
    /// Файлы уже на диске — не ждём ничего: задача скачивания может не завершиться и после
    /// того, как модель легла целиком, и тогда диктовка вечно висит на «Загружаю модель…».
    /// Зовётся только с `queue`.
    func pendingDownload(forVariant variant: String) -> Task<Void, Error>? {
        store.isInstalled(variant: variant) ? nil : downloading[variant]
    }

    /// Ждёт задачу, но не дольше отведённого срока. Саму задачу не трогает: она чужая,
    /// её ведёт тот, кто начал, — мы лишь перестаём на неё рассчитывать.
    /// Возвращает, сколько прождали, — это единственное, что потом объясняет паузу.
    private static func wait(for task: Task<Void, Error>, upTo limit: Duration) async -> TimeInterval {
        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await task.value }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
        return Date().timeIntervalSince(started)
    }

    /// Скачивание без прогрева. Как и `loadTask`, снимает себя со списка идущих —
    /// и при успехе, и при ошибке.
    private func downloadTask(
        variant: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) -> Task<Void, Error> {
        Task {
            defer { self.queue.sync { self.downloading[variant] = nil } }
            try await downloadVariant(variant, onProgress)
            // Оборванное скачивание HubApi возвращает молча, не бросая: недокачанную папку
            // на диске от готовой отличает только этот флаг.
            try Task.checkCancellation()
        }
    }

    /// То же самое для модели превью: прогресс никому не показываем — загрузка идёт
    /// фоном при старте приложения, а до её конца превью считает большая модель.
    private func previewLoadTask() -> Task<Void, Error> {
        Task {
            do {
                let pipe = try await Self.loadPipeline(
                    variant: Self.previewVariant,
                    store: store,
                    onState: { _ in }
                )
                self.queue.sync {
                    self.previewPipeline = pipe
                    self.previewLoading = nil
                }
            } catch {
                self.queue.sync { self.previewLoading = nil }
                throw error
            }
        }
    }

    /// Скачивание (только если моделей ещё нет на диске) + прогрев одного варианта.
    private static func loadPipeline(
        variant: String,
        store: ModelStore,
        onState: @escaping @Sendable (ASRModelState) -> Void
    ) async throws -> WhisperKit {
        let folder: URL
        if let local = store.installedFolder(variant: variant) {
            folder = local
        } else {
            onState(.downloading(0))
            folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: store.base,
                progressCallback: { progress in onState(.downloading(progress.fractionCompleted)) }
            )
        }

        onState(.loading)
        return try await WhisperKit(
            WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: store.base,
                prewarm: true,
                load: true
            )
        )
    }

    /// Токены промпта без спецтокенов — их WhisperKit подставляет сам.
    private func promptTokens(_ prompt: String, pipe: WhisperKit) -> [Int]? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let tokenizer = pipe.tokenizer else { return nil }

        let count: (String) -> Int = { Self.contentTokens($0, tokenizer: tokenizer).count }
        let tokens = Self.contentTokens(Self.fitted(text, count: count), tokenizer: tokenizer)
        return tokens.isEmpty ? nil : Self.capped(tokens)
    }

    private static func contentTokens(_ text: String, tokenizer: WhisperTokenizer) -> [Int] {
        tokenizer
            .encode(text: " " + text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    /// Сколько токенов окна отдаём промпту — меньше трети контекста декодера.
    ///
    /// Контекст у CoreML-декодера WhisperKit — 224 токена, и промпт ест их наравне с самой
    /// расшифровкой: цикл декодера обрывается по `currentTokens.count >= 223`, а
    /// `currentTokens` начинается ровно с промпта. WhisperKit разрешает промпту половину
    /// (111 токенов) — ту же долю, что и эталонный Whisper, но у того контекст вдвое больше
    /// (448), и расшифровке остаётся 224 токена против наших 112.
    ///
    /// Чем это кончается: когда бюджет исчерпан, поток токенов обрывается посреди слова,
    /// WhisperKit штампует всё окно одним сегментом и перематывает `seek` за его конец —
    /// нерасшифрованный звук выбрасывается молча, без единой ошибки.
    ///
    /// Замер потерь по длине промпта (в токенах настоящего токенайзера), 115 c быстрой русской
    /// речи, эталон 309 слов: 56 → 309, 64 → 309, 70 → 309, 74 → 309, 78 → 306, 84 → 300,
    /// 98 → 286, 111 → 266. На той же диктовке в обычном темпе (141 c) обрыв начинается позже:
    /// 84 → 309, 98 → 304. То есть граница зависит от плотности речи, и считать надо по
    /// быстрой: 64 токена — на 18 % ниже первой потери и вдвое ниже того, что разрешает сам
    /// WhisperKit (111).
    ///
    /// Больше 64 стоило бы взять только ради терминов, но и так доезжает восемь из 36:
    /// образец пунктуации с рамкой стоит 33 токена, каждый следующий термин — ещё 3–4,
    /// и платить за него пришлось бы речью, а речь дороже.
    static let maxPromptTokens = 64

    /// Промпт длиннее бюджета режем с начала и только по границам терминов: `PromptBuilder`
    /// ставит важное в хвост, а термины перечисляет через запятую в начале. Слепой срез по
    /// токенам рвал промпт посреди слова — английская сессия начиналась с «GPT,» (огрызок
    /// «ChatGPT»).
    static func fitted(_ text: String, count: (String) -> Int) -> String {
        var text = text
        while count(text) > maxPromptTokens, let comma = text.range(of: ", ") {
            text = String(text[comma.upperBound...])
        }
        return text
    }

    /// Страховка на случай, когда резать по терминам уже нечего: хвост промпта важнее начала,
    /// и WhisperKit сам обрезает промпт тем же концом.
    static func capped(_ tokens: [Int]) -> [Int] {
        Array(tokens.suffix(maxPromptTokens))
    }
}
