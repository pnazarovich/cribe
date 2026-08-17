import Foundation
import CribeCore
import FluidAudio
import WhisperKit

private let usage = """
usage: cribe-cli <audio-file> --lang ru|uk|en [--variant NAME] [--parakeet] [--no-prompt] [--no-gpt] [--no-vad] [--translate] [--neighbour] [--words]

  --lang ru|uk|en  язык диктовки (обязателен)
  --variant NAME   вариант модели вместо выбранного языком: например
                   openai_whisper-large-v3 для русской записи, которую обычно
                   разбирает turbo. Ради замера «какая модель слышит лучше» —
                   сравнивать модели иначе не на чем.
  --parakeet     распознавать не Whisper, а Parakeet TDT v3 от NVIDIA (FluidAudio).
                 Замерный режим: словарной подсказки у него нет по устройству,
                 поэтому сравнивать честно можно только слой 1.
  --no-prompt    не подсказывать Whisper словарные термины: замер «не портит ли
                 подсказка то, что модель услышала бы сама»
  --no-gpt       без слоя 3 (GPT-чистки)
  --no-vad       без обрезки тишины
  --translate    вернуть английский перевод (переводит сама модель, слой 1)
  --neighbour    перечитывать фразы, звучащие на соседнем языке (в приложении — настройка;
                 своим ключом, потому что у CLI собственный домен UserDefaults)
  --words        замерный режим: уверенность распознавания по каждому слову и найденные
                 по ней сломанные куски (см. `Uncertainty`). Текста не печатает.
  --gpt-model NAME   модель слоя 3 вместо выбранной в настройках (gpt-5.6-luna,
                 gpt-5.6-terra, gpt-5.6-sol). Ради замера «хватит ли модели подешевле».
  --gpt-effort X     усилие рассуждения слоя 3: none|minimal|low|medium|high.
                 Codex-бэкенд ниже low не опускается и сам нормализует.

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

        // Другой движок целиком: у него ни подсказки, ни второго мнения — только слой 1.
        if options.parakeet {
            log("Parakeet TDT v3 — подготовка…")
            // Именно многоязычный набор: у «unified» варианта модель английская,
            // и русская запись возвращается пустой строкой.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager()
            try await manager.loadModels(models)
            log("распознавание…")
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(
                speech,
                decoderState: &state,
                // Тип берётся из подписи: имя `Language` в этом файле занято нашим.
                language: .init(rawValue: options.language.rawValue)
            )
            log("слой 1: \(result.text)")
            // Дальше — общий конвейер: словарь и GPT движка не касаются, и сравнивать
            // движки честно можно только по одинаковому пути.
            let entries = UserDictionary(url: UserDictionary.defaultURL).entries
            let replaced = ReplacementEngine.apply(result.text, entries: entries)
            log("слой 2: \(replaced)")
            return try await cleaned(replaced, entries: entries, options: options)
        }

        let engine = WhisperEngine()
        // Ловля соседнего языка: в приложении это настройка, здесь — флаг.
        engine.checksNeighbourLanguage = options.neighbour
        let progress = ModelProgress()
        let variant = options.variant ?? options.language.whisperModel
        log("модель \(variant) — подготовка…")
        try await engine.prepare(variant: variant, language: options.language) { progress.report($0) }
        // Второе мнение спрашивают у прогретой модели соседа: в приложении её греют заранее,
        // здесь — прямо сейчас, иначе первый же прогон отложил бы проверку.
        if options.neighbour, let neighbour = options.language.neighbour {
            log("модель соседа \(neighbour.whisperModel) — подготовка…")
            try await engine.prepare(variant: neighbour.whisperModel, language: neighbour) { _ in }
        }

        let entries = UserDictionary(url: UserDictionary.defaultURL).entries
        log("словарь: \(entries.count) терминов")
        // Замерный режим: печатаем уверенность по словам и найденные по ней сломанные куски.
        if options.words {
            let pass = try await engine.transcribeDetailed(
                speech,
                language: options.language,
                variant: variant,
                prompt: PromptBuilder.initialPrompt(entries: entries, language: options.language)
            )
            for probe in pass.words {
                print(String(format: "%.3f\t%@", probe.probability, probe.word))
            }
            for run in Uncertainty.runs(in: pass.words) {
                log("цепочка: \(run.text)")
            }
            return ""
        }
        log("распознавание…")
        let prompt = options.usePrompt
            ? PromptBuilder.initialPrompt(entries: entries, language: options.language)
            : ""
        let raw: String
        var heardWords: [WordProbe] = []
        if options.translate {
            raw = try await engine.transcribe(
                speech, language: options.language, prompt: prompt, translating: true
            )
        } else {
            let pass = try await engine.transcribeDetailed(
                speech, language: options.language, variant: variant, prompt: prompt
            )
            raw = pass.text
            heardWords = pass.words
        }
        // Те же ворота, что и в конвейере: нет цепочки неуверенных слов — ломаться нечему,
        // и за дорогую сверку соседним языком не платим.
        let shaky = Uncertainty.runs(in: heardWords)
        for run in shaky { log("цепочка: \(run.text)") }
        let checked = shaky.isEmpty
            ? NeighbourPass(text: raw)
            : await engine.reconsideringNeighbour(
                raw, samples: speech, language: options.language, prompt: prompt
            )
        if checked.replaced > 0 { log("перечитано фраз на соседнем языке: \(checked.replaced)") }
        if let alarm = Uncertainty.alarm(runs: shaky, reread: checked.phrases) {
            log("предупреждение: \(alarm)")
        }
        log("слой 1: \(checked.text)")

        let text = ReplacementEngine.apply(checked.text, entries: entries)
        log("слой 2: \(text)")
        return try await cleaned(text, entries: entries, options: options)
    }

    /// Слой 3 общий для обоих движков: сравнивать их иначе нечестно.
    private static func cleaned(
        _ text: String,
        entries: [DictionaryEntry],
        options: Options
    ) async throws -> String {
        guard options.useGPT else { return text }

        log(options.translate ? "слой 3: чистка и перевод…" : "слой 3: чистка…")
        do {
            return try await PostProcessor.cleanup(
                text: text,
                entries: entries,
                language: options.language,
                config: options.gptConfig,
                timeout: 40,
                translateToEnglish: options.translate,
                restoreUkrainianInserts: AppSettings.shared.restoreUkrainianInserts,
                engine: options.parakeet ? .parakeet : .fast,
                keepsNeighbourLanguage: options.neighbour
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
    let language: CribeCore.Language
    let useGPT: Bool
    let useVAD: Bool
    let translate: Bool
    let neighbour: Bool
    let words: Bool
    let variant: String?
    let usePrompt: Bool
    let parakeet: Bool
    let gptModel: String?
    let gptEffort: String?

    /// Настройки слоя 3 с поправкой на замерные флаги: не указаны — берём как у приложения.
    var gptConfig: GPTConfig {
        let base = AppSettings.shared.gptConfig
        return GPTConfig(mode: base.mode, model: gptModel ?? base.model, effort: gptEffort ?? base.effort)
    }

    init(arguments: [String]) throws {
        var path: String?
        var language: CribeCore.Language?
        var useGPT = true
        var useVAD = true
        var translate = false
        var neighbour = false
        var words = false
        var variant: String?
        var usePrompt = true
        var parakeet = false
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
            case "--no-prompt": usePrompt = false
            case "--parakeet": parakeet = true
            case "--no-vad": useVAD = false
            case "--translate": translate = true
            case "--neighbour": neighbour = true
            case "--words": words = true
            case "--variant":
                guard let value = rest.next() else {
                    throw CLIError("--variant требует имя варианта модели\n\n\(usage)")
                }
                variant = value
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
        self.words = words
        self.variant = variant
        self.usePrompt = usePrompt
        self.gptModel = gptModel
        self.gptEffort = gptEffort
        self.parakeet = parakeet
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
