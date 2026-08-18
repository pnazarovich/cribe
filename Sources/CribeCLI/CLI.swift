import Foundation
import CribeCore
import WhisperKit

private let usage = """
usage: cribe-cli <audio-file> --lang ru|uk|en [--no-gpt] [--no-vad] [--translate] [--neighbour]

  --lang ru|uk|en  язык диктовки (обязателен)
  --no-gpt       без слоя 3 (GPT-чистки)
  --no-vad       без обрезки тишины
  --translate    вернуть английский перевод (переводит слой 3 — распознавание не умеет)
  --neighbour    считать, что в настройках включена ловля соседнего языка: слой 3 тогда
                 бережёт украинские вставки, а не приводит их к русскому написанию
                 (своим ключом, потому что у CLI собственный домен UserDefaults)
  --gpt-model NAME   модель слоя 3 вместо выбранной в настройках (gpt-5.6-luna,
                 gpt-5.6-terra, gpt-5.6-sol). Ради замера «хватит ли модели подешевле».
  --gpt-effort X     усилие рассуждения слоя 3: none|minimal|low|medium|high.
                 Codex-бэкенд ниже low не опускается и сам нормализует.

Стадии печатаются в stderr, финальный текст — в stdout.
"""

/// Прогон конвейера над файлом, минуя запись и вставку: чтение → VAD → Parakeet → словарь → GPT.
@main
struct CLI {
    static func main() async {
        do {
            let options = try Options(arguments: CommandLine.arguments)
            print(try await run(options))
        } catch {
            log("ошибка: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func run(_ options: Options) async throws -> String {
        let recorded = try AudioProcessor.loadAudioAsFloatArray(fromPath: options.path)
        log("аудио: \(recorded.count) сэмплов ≈ \(seconds(recorded.count)) c @ 16 кГц")

        // Тот же подъём уровня, что и в приложении: без него тихая запись (низкая громкость
        // входа в системе) распознаётся заметно хуже — см. `AudioNormalizer`. CLI обязан
        // повторять конвейер, иначе замер по нему ничего не значит.
        let peak = AudioNormalizer.peak(recorded)
        let samples = AudioNormalizer.normalized(recorded)
        log(
            "уровень: пик \(String(format: "%.4f", peak)) "
                + "→ ×\(String(format: "%.1f", AudioNormalizer.gain(forPeak: peak)))"
        )

        var speech = samples
        if options.useVAD {
            guard let trimmed = try await VadGate().trimmed(samples) else {
                throw CLIError("речь не обнаружена")
            }
            speech = trimmed
            log("VAD: \(seconds(trimmed.count)) c речи")
        }

        let engine = ParakeetEngine()
        let progress = ModelProgress()
        log("Parakeet TDT v3 — подготовка…")
        try await engine.prepare(language: options.language) { progress.report($0) }

        log("распознавание…")
        // Подсказки у Parakeet нет по устройству — словарь работает только слоями 2 и 3.
        let heard = try await engine.transcribe(speech, language: options.language, prompt: "")
        log("слой 1: \(heard)")

        let entries = UserDictionary(url: UserDictionary.defaultURL).entries
        log("словарь: \(entries.count) терминов")
        let text = ReplacementEngine.apply(heard, entries: entries)
        log("слой 2: \(text)")

        guard options.useGPT else {
            if options.translate { throw CLIError("--translate без слоя 3 невозможен: переводит GPT") }
            return text
        }

        log(options.translate ? "слой 3: чистка и перевод…" : "слой 3: чистка…")
        do {
            return try await PostProcessor.cleanup(
                text: text,
                entries: entries,
                language: options.language,
                config: options.gptConfig,
                timeout: 40,
                // Английский: у CLI своя роль — замерять слой 3, а не повторять настройки
                // приложения. Понадобится мерить другой язык — придёт своим флагом.
                translateTo: options.translate ? .en : nil,
                mixesUkrainian: options.neighbour
            )
        } catch {
            // Перевод делает только слой 3: не отработал — переводить нечем, и молча отдавать
            // русский текст под видом английского нельзя.
            if options.translate { throw error }
            // Чистка не обязательна: отдаём результат слоя 2 и предупреждаем.
            log("предупреждение: слой 3 не отработал (\(error.localizedDescription)) — текст слоя 2")
            return text
        }
    }

    private static func seconds(_ sampleCount: Int) -> String {
        String(format: "%.1f", Double(sampleCount) / 16_000)
    }
}

private struct Options {
    let path: String
    let language: CribeCore.Language
    let useGPT: Bool
    let useVAD: Bool
    let translate: Bool
    let neighbour: Bool
    let gptModel: String?
    let gptEffort: String?

    /// Настройки слоя 3 с поправкой на замерные флаги: не указаны — берём как у приложения.
    var gptConfig: GPTConfig {
        let base = translate ? AppSettings.shared.translateGPTConfig : AppSettings.shared.gptConfig
        return GPTConfig(mode: base.mode, model: gptModel ?? base.model, effort: gptEffort ?? base.effort)
    }

    init(arguments: [String]) throws {
        var path: String?
        var language: CribeCore.Language?
        var useGPT = true
        var useVAD = true
        var translate = false
        var neighbour = false
        var gptModel: String?
        var gptEffort: String?

        var rest = arguments.dropFirst().makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--lang":
                guard let value = rest.next(), let parsed = CribeCore.Language(rawValue: value) else {
                    throw CLIError("--lang требует значение ru, uk или en\n\n\(usage)")
                }
                language = parsed
            case "--no-gpt": useGPT = false
            case "--no-vad": useVAD = false
            case "--translate": translate = true
            case "--neighbour": neighbour = true
            case "--gpt-model":
                guard let value = rest.next() else {
                    throw CLIError("--gpt-model требует имя модели\n\n\(usage)")
                }
                gptModel = value
            case "--gpt-effort":
                guard let value = rest.next() else {
                    throw CLIError("--gpt-effort требует none|minimal|low|medium|high\n\n\(usage)")
                }
                gptEffort = value
            case "-h", "--help": throw CLIError(usage)
            default:
                guard !argument.hasPrefix("-"), path == nil else {
                    throw CLIError("неизвестный аргумент «\(argument)»\n\n\(usage)")
                }
                path = argument
            }
        }

        guard let path else { throw CLIError("не указан аудиофайл\n\n\(usage)") }
        guard let language else { throw CLIError("не указан --lang\n\n\(usage)") }

        self.path = path
        self.language = language
        self.useGPT = useGPT
        self.useVAD = useVAD
        self.translate = translate
        self.neighbour = neighbour
        self.gptModel = gptModel
        self.gptEffort = gptEffort
    }
}

private struct CLIError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// Прогресс скачивания приходит из фоновой задачи и часто — печатаем шагами по 5 %.
private final class ModelProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -5

    func report(_ state: ASRModelState) {
        switch state {
        case .downloading(let fraction):
            let percent = Int(fraction * 100)
            lock.lock()
            let show = percent >= lastPercent + 5
            if show { lastPercent = percent }
            lock.unlock()
            if show { log("скачивание модели: \(percent) %") }
        case .loading: log("загрузка модели в память…")
        case .ready: log("модель готова")
        case .notLoaded: log("модель не загружена")
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
