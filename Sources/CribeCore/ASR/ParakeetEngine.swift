import FluidAudio
import Foundation
import OSLog

/// Распознавание на Parakeet TDT v3 (NVIDIA) через FluidAudio.
///
/// **Чем берёт.** Другая архитектура и другой размер: 0,6 млрд параметров против 0,8 у
/// turbo, и вдесятеро быстрее. Замер на живой записи: 0,4 c против 4,3 c у turbo и 8,3 c
/// у large-v3, вместе с загрузкой модели. Пунктуацию и заглавные ставит сам.
///
/// **Чем платит.** Латинские слова он записывает кириллицей — «Гитхаб», «пул реквест»,
/// «крайб». Это не мелочь, а его устройство: обучали на европейских языках каждый в своём
/// алфавите. Поэтому GPT-слой с ним не роскошь, а часть движка — только он возвращает
/// названиям латиницу (см. `PostProcessor`), и короткие диктовки мимо него не пускаются
/// (см. `ShortDictation`).
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

    public init() {}

    /// Лежат ли файлы модели на диске. Нужно прогреву при запуске ровно затем же, зачем
    /// и у Whisper: `prepare` без файлов полез бы их качать, а полгигабайта в фоне без
    /// спроса не качают.
    public static var isInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
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
        let task: Task<AsrManager, Error> = queue.sync {
            if let loading { return loading }
            let started = Task<AsrManager, Error> {
                // Именно многоязычный набор: у «unified»-варианта модель английская,
                // и русская запись возвращается пустой строкой.
                let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
                    switch progress.phase {
                    case .listing, .downloading:
                        onState?(.downloading(progress.fractionCompleted))
                    case .compiling:
                        // Компиляция под ANE — уже не сеть: показывать её долей скачанного
                        // значило бы врать полосой, которая стоит на месте.
                        onState?(.loading)
                    }
                }
                let manager = AsrManager()
                try await manager.loadModels(models)
                Self.logger.notice("Parakeet TDT v3 готов")
                return manager
            }
            loading = started
            return started
        }
        do {
            let manager = try await task.value
            queue.sync { self.manager = manager }
            return manager
        } catch {
            // Неудачную загрузку не кэшируем: следующая диктовка вправе попробовать снова.
            queue.sync { loading = nil }
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
            // Тип берётся из подписи: имя `Language` тут занято нашим.
            language: .init(rawValue: language.rawValue)
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
}
