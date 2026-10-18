import FluidAudio
import Foundation
import OSLog

/// Распознавание на Parakeet Ultra через FluidAudio.
///
/// **Чем берёт.** Ultra — дообученный Parakeet TDT 0.6B v3 (NVIDIA): та же архитектура,
/// токенизатор и скорость на Neural Engine, другие веса. На FLEURS ошибок меньше на 12–14%
/// по-русски и на 17–20% по-украински (два независимых стенда). Замер на 18 записях
/// владельца 2026-10-18: 5,9% против 7,3% у v3 — вместе со снятием подсказки письменности
/// (см. `scriptHint`). Пунктуацию и заглавные ставит сам.
///
/// **Чем платит.** Часть английских названий всё равно пишет кириллицей, на слух
/// («гип ресерч»). Латиницу остальным возвращает GPT-слой (см. `PostProcessor`), и короткие
/// диктовки мимо него не пускаются (см. `ShortDictation`).
///
/// **Чего не умеет.** Подсказки словарём (у CTC/TDT нет входа для промпта — словарь
/// работает только вторым слоем), перевода задачей декодера, сегментов с таймкодами
/// и пословной уверенности. Всё это законные пробелы: конвейер на них рассчитан
/// (см. умолчания `TranscriptionEngine`) и просто не включает соответствующие приёмы.
public final class ParakeetEngine: TranscriptionEngine, @unchecked Sendable {
    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Parakeet")

    private let queue = DispatchQueue(label: "online.nazarovych.cribe.parakeet")
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private let progress = ProgressFanout()

    /// Какие веса грузит приложение.
    public static let defaultVersion: AsrModelVersion = .ultra

    /// Как модель называется в интерфейсе.
    public static let displayName = "Parakeet Ultra"

    public init() {}

    /// Лежат ли файлы модели на диске. Нужно прогреву при запуске ровно затем же, зачем
    /// и у Whisper: `prepare` без файлов полез бы их качать, а полгигабайта в фоне без
    /// спроса не качают.
    public static var isInstalled: Bool { installed(defaultVersion) }

    /// Лежат ли веса прежней версии (v3) — то есть обновляется ли человек с Parakeet,
    /// а не с Whisper. Окну обновления это меняет весь рассказ: «перешли на Parakeet»
    /// тому, кто на нём уже сидел, было бы неправдой.
    public static var hasPreviousVersion: Bool { installed(.v3) }

    static func installed(_ version: AsrModelVersion) -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    /// Модель одна на все языки — она многоязычная, и `language` тут не выбирает вес,
    /// а только называет язык проходу.
    public func prepare(language: Language, onState: @escaping @Sendable (ASRModelState) -> Void) async throws {
        if queue.sync(execute: { manager }) != nil {
            onState(.ready)
            return
        }
        onState(Self.isInstalled ? .loading : .downloading(0))
        do {
            _ = try await ready(onState: onState)
            onState(.ready)
        } catch {
            onState(.notLoaded)
            throw error
        }
    }

    /// Прогретый менеджер. Параллельные вызовы склеиваются в одну загрузку: модель весит
    /// сотни мегабайт, и качать её дважды незачем.
    private func ready(onState: (@Sendable (ASRModelState) -> Void)? = nil) async throws -> AsrManager {
        // Подписка — до того, как решаем, начинать загрузку или присоединиться к идущей:
        // так и начавший, и присоединившийся получают одни и те же доли.
        let catchUp = progress.join(onState)
        let task: Task<AsrManager, Error> = queue.sync {
            if let loading { return loading }
            let started = Task<AsrManager, Error> {
                // Именно многоязычный набор: у «unified»-варианта модель английская,
                // и русская запись возвращается пустой строкой.
                let models = try await AsrModels.downloadAndLoad(version: Self.defaultVersion) { progress in
                    switch progress.phase {
                    case .listing, .downloading:
                        self.progress.send(.downloading(progress.fractionCompleted))
                    case .compiling:
                        // Компиляция под ANE — уже не сеть: показывать её долей скачанного
                        // значило бы врать полосой, которая стоит на месте.
                        self.progress.send(.loading)
                    }
                }
                let manager = AsrManager()
                try await manager.loadModels(models)
                Self.logger.notice("\(Self.displayName, privacy: .public) готов")
                return manager
            }
            loading = started
            return started
        }
        // Присоединившемуся к идущей загрузке — сразу последнее известное состояние,
        // а не ноль до следующей доли.
        if let catchUp { onState?(catchUp) }
        do {
            let manager = try await task.value
            queue.sync { self.manager = manager }
            progress.reset()
            return manager
        } catch {
            // Неудачную загрузку не кэшируем: следующая диктовка вправе попробовать снова.
            queue.sync { loading = nil }
            progress.reset()
            throw error
        }
    }

    public func transcribe(_ samples: [Float], language: Language, prompt: String) async throws -> String {
        // Промпт не передаётся намеренно: входа для него у модели нет, и молча делать вид,
        // что словарь учтён, нельзя — его применяет второй слой.
        let manager = try await ready()
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(
            samples,
            decoderState: &state,
            // Тип берётся из подписи: имя `Language` тут занято нашим, а `FluidAudio.Language`
            // не назвать — модуль перекрыт одноимённой структурой.
            language: Self.scriptHint(for: language).flatMap { .init(rawValue: $0) }
        )
        return result.text
    }

    /// Перевод задачей декодера этот движок не умеет — и молчать об этом нельзя: обычный
    /// проход вернул бы русский текст под видом английского.
    public func transcribe(
        _ samples: [Float],
        language: Language,
        prompt: String,
        translating: Bool
    ) async throws -> String {
        guard !translating else { throw TranscriptionEngineError.translationUnsupported }
        return try await transcribe(samples, language: language, prompt: prompt)
    }

    /// Какую письменность разрешить декодеру — для русского и украинского никакую.
    ///
    /// Параметр `language` у FluidAudio не выбирает веса — модель одна на все языки, —
    /// а включает фильтр письменности: на каждом шаге декодер берёт лучший токен из тех,
    /// чей алфавит совпадает с языком. Кириллическая ветка фильтра явно отбрасывает любой
    /// токен с латинскими буквами. Мы передавали язык с первого дня — и сами запрещали
    /// модели латиницу: «Гитхаб» вместо GitHub считалось её устройством, а было нашей
    /// настройкой.
    ///
    /// Замер 2026-10-18 на 18 записях владельца: без подсказки 7 английских названий из 15
    /// пришли латиницей прямо из распознавания (с подсказкой — ни одного), а ложной латиницы
    /// в русских словах — ноль. Синтетический украинский дал то же самое. Английской сессии
    /// подсказку оставляем: там фильтр отсекает кириллицу, ради чего и написан.
    static func scriptHint(for language: Language) -> String? {
        language.isCyrillic ? nil : language.rawValue
    }
}

/// Прогресс одной загрузки — всем, кто её ждёт.
///
/// Загрузку модели склеивают: второй желающий не качает заново, а ждёт уже идущую. Раньше
/// прогресс при этом получал только тот, кто её начал. При обновлении первым её начинает
/// окно обновления, и диктовка, нажатая в это время, весь download и всю компиляцию
/// показывала «Качаю модель… 0%» — как зависание, при том что в окне процент рос.
///
/// Слушателей зовём вне замка: они ставят обновление интерфейса в очередь и могут
/// дёрнуть движок обратно — под замком это была бы взаимная блокировка.
final class ProgressFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [@Sendable (ASRModelState) -> Void] = []
    private var last: ASRModelState?

    /// Подписаться. Возвращает последнее известное состояние — чтобы присоединившийся
    /// к идущей загрузке не стоял на нуле до следующей доли.
    func join(_ listener: (@Sendable (ASRModelState) -> Void)?) -> ASRModelState? {
        lock.lock()
        defer { lock.unlock() }
        if let listener { listeners.append(listener) }
        return last
    }

    func send(_ state: ASRModelState) {
        lock.lock()
        last = state
        let targets = listeners
        lock.unlock()
        targets.forEach { $0(state) }
    }

    /// Загрузка кончилась — удачно или нет. Следующая начнётся с чистого листа.
    func reset() {
        lock.lock()
        listeners.removeAll()
        last = nil
        lock.unlock()
    }
}
