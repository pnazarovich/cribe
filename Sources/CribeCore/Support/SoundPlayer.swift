import AVFoundation
import Foundation
import OSLog

/// Короткие чаймы старта и остановки записи. Синтезируются в памяти при создании
/// `shared` — ни файлов, ни ресурсов в бандле.
public final class SoundPlayer {
    public static let shared = SoundPlayer()

    /// Синтез в 44.1 кГц: чайм идёт в динамики, а не через 16-кГц тракт записи.
    static let sampleRate = 44_100

    /// Тембр почти чистого тона: основной и один тихий обертон. Выбран владельцем из
    /// пяти вариантов — самый сдержанный. Богатый обертонами звук в наушниках лезет
    /// вперёд и отвлекает, а этот ближе к щелчку, чем к мелодии: его слышно и тут же
    /// забываешь, чего от служебного чайма и хочется.
    private static let partials: [(ratio: Double, gain: Double, damping: Double)] = [
        (ratio: 1, gain: 1, damping: 1),        // основной тон
        (ratio: 2, gain: 0.050, damping: 2.5),  // −26 дБ, гаснет вдвое быстрее
    ]

    /// Атака приподнятым косинусом. Здесь она заметно мягче удара молоточка: на низкой
    /// ноте резкий фронт слышен как щелчок динамика.
    private static let attack = 0.012
    /// Постоянная времени спада в долях длины ноты: меньше — суше звук.
    private static let damping = 0.35
    /// Ноты накладываются: вторая входит, пока первая ещё звенит, и стыка не слышно.
    private static let overlap = 0.4
    private static let noteLength = 0.10
    /// Последняя нота догорает дольше — после неё ничего не следует.
    private static let tailLength = 0.16
    /// Тишина по краям файла: устройство получает нули до и после чайма.
    private static let padding = 0.006
    /// Общий фейд в конце — страховка поверх огибающих нот.
    private static let masterFade = 0.01

    private static let peak: Float = 0.5
    private static let volume: Float = 0.3

    /// Низкий регистр намеренно: чайм не должен перекрикивать речь, ради которой его и
    /// слышат. Кварта та же, что и была, но на октаву ниже.
    private static let g3 = 196.0
    private static let c4 = 261.63

    /// Восходящая кварта: запись пошла.
    static let startWav = wav(frequencies: [g3, c4])
    /// Та же пара наоборот — спокойный ответ на остановку.
    static let stopWav = wav(frequencies: [c4, g3])

    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "SoundPlayer")

    private let startPlayer: AVAudioPlayer?
    private let stopPlayer: AVAudioPlayer?

    /// Каталог пользовательских звуков: `start.*`/`stop.*` здесь перекрывают синтез.
    /// Кладём любые форматы, понятные AVAudioPlayer (wav/m4a/mp3/caf/aiff).
    public static let customSoundsDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cribe/sounds", isDirectory: true)

    private static func customPlayer(named name: String) -> AVAudioPlayer? {
        let dir = customSoundsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        guard let url = files.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) else { return nil }
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            logger.error("не удалось загрузить пользовательский звук \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        player.volume = volume
        player.prepareToPlay()
        return player
    }

    /// Синтез и `prepareToPlay` — сразу: на первом хоткее чайм иначе опаздывал.
    /// Пользовательские файлы (start.*/stop.* в Application Support/Cribe/sounds)
    /// имеют приоритет над синтезированными чаймами.
    private init() {
        startPlayer = Self.customPlayer(named: "start") ?? Self.player(Self.startWav)
        stopPlayer = Self.customPlayer(named: "stop") ?? Self.player(Self.stopWav)
    }

    /// Прогрев на старте приложения: создаёт `shared`, а с ним — оба готовых плеера.
    public static func preload() { _ = shared }

    public func playStart() { restart(startPlayer) }

    public func playStop() { restart(stopPlayer) }

    /// Тот же плеер переиспользуется: повторный старт — с нулевой позиции.
    private func restart(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private static func player(_ data: Data) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(data: data)
            player.volume = volume
            player.prepareToPlay()
            return player
        } catch {
            logger.error("Чайм не создан: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Синтез

    static func wav(frequencies: [Double]) -> Data {
        WavEncoder.encode(mix(frequencies), sampleRate: sampleRate)
    }

    /// Каждая нота рендерится в свой буфер и складывается с наложением: на стыке нот
    /// звучит сумма двух непрерывных сигналов, поэтому разрыва там быть не может.
    private static func mix(_ frequencies: [Double]) -> [Float] {
        let step = Int(noteLength * (1 - overlap) * Double(sampleRate))
        let pad = Int(padding * Double(sampleRate))
        let notes = frequencies.enumerated().map { index, frequency in
            note(frequency, length: index == frequencies.count - 1 ? tailLength : noteLength)
        }

        let end = notes.indices.map { pad + $0 * step + notes[$0].count }.max() ?? pad
        var buffer = [Float](repeating: 0, count: end + pad)
        for (index, note) in notes.enumerated() {
            let offset = pad + index * step
            for (sample, value) in note.enumerated() { buffer[offset + sample] += value }
        }

        let fade = Int(masterFade * Double(sampleRate))
        for index in 0..<fade {
            buffer[end - fade + index] *= Float(0.5 * (1 + cos(.pi * Double(index) / Double(fade))))
        }

        // Наложение нот складывается — нормируем, иначе кодировщик срежет пики.
        let loudest = buffer.reduce(Float(0)) { max($0, abs($1)) }
        guard loudest > 0 else { return buffer }
        return buffer.map { $0 / loudest * peak }
    }

    private static func note(_ frequency: Double, length: Double) -> [Float] {
        let count = Int(length * Double(sampleRate))
        let tau = length * damping
        return (0..<count).map { sample in
            let time = Double(sample) / Double(sampleRate)
            let wave = partials.reduce(0.0) { sum, partial in
                sum + partial.gain * exp(-time * partial.damping / tau)
                    * sin(2 * .pi * frequency * partial.ratio * time)
            }
            return Float(wave * envelope(time, length: length))
        }
    }

    /// Приподнятый косинус на атаке и на всём спаде: нота начинается и заканчивается
    /// ровным нулём, причём с нулевой производной — щёлкнуть там нечему.
    private static func envelope(_ time: Double, length: Double) -> Double {
        if time < attack { return 0.5 * (1 - cos(.pi * time / attack)) }
        return 0.5 * (1 + cos(.pi * min(1, (time - attack) / (length - attack))))
    }
}
