import Foundation
import CribeCore
import WhisperKit

private let usage = """
usage: cribe-cli <audio-file> --lang ru|uk|en [--no-gpt] [--no-vad] [--translate]

  --lang ru|uk|en  язык диктовки (обязателен)
  --no-gpt       без слоя 3 (GPT-чистки)
  --no-vad       без обрезки тишины
  --translate    вернуть английский перевод (переводит сама модель, слой 1)

Стадии печатаются в stderr, финальный текст — в stdout.
"""

/// Прогон конвейера над файлом, минуя запись и вставку: чтение → VAD → Whisper → словарь → GPT.
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

        let engine = WhisperEngine()
        let progress = ModelProgress()
        log("модель \(options.language.whisperModel) — подготовка…")
        try await engine.prepare(language: options.language) { progress.report($0) }

        let entries = UserDictionary(url: UserDictionary.defaultURL).entries
        log("словарь: \(entries.count) терминов")
        log("распознавание…")
        let raw = try await engine.transcribe(
            speech,
            language: options.language,
            prompt: PromptBuilder.initialPrompt(entries: entries, language: options.language),
            translating: options.translate
        )
        log("слой 1: \(raw)")

        let text = ReplacementEngine.apply(raw, entries: entries)
        log("слой 2: \(text)")
        guard options.useGPT else { return text }

        log(options.translate ? "слой 3: чистка и перевод…" : "слой 3: чистка…")
        do {
            return try await PostProcessor.cleanup(
                text: text,
                entries: entries,
                language: options.language,
                config: AppSettings.shared.gptConfig,
                timeout: 10,
                translateToEnglish: options.translate,
                restoreUkrainianInserts: AppSettings.shared.restoreUkrainianInserts
            )
        } catch {
            // Слой 3 не обязателен: отдаём результат слоя 2 и предупреждаем.
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
    let language: Language
    let useGPT: Bool
    let useVAD: Bool
    let translate: Bool

    init(arguments: [String]) throws {
        var path: String?
        var language: Language?
        var useGPT = true
        var useVAD = true
        var translate = false

        var rest = arguments.dropFirst().makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--lang":
                guard let value = rest.next(), let parsed = Language(rawValue: value) else {
                    throw CLIError("--lang требует значение ru, uk или en\n\n\(usage)")
                }
                language = parsed
            case "--no-gpt": useGPT = false
            case "--no-vad": useVAD = false
            case "--translate": translate = true
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
