import AVFoundation
import Foundation
import OSLog

/// Короткие чаймы старта и остановки записи. Синтезируются в памяти при первом
/// обращении — ни файлов, ни ресурсов в бандле.
public final class SoundPlayer {
    public static let shared = SoundPlayer()

    /// Синтез в 44.1 кГц: чайм идёт в динамики, а не через 16-кГц тракт записи.
    static let sampleRate = 44_100
    /// Мягкая огибающая: без неё короткая нота щёлкает на старте и в конце.
    private static let attack = 0.01
    private static let decay = 0.08
    /// Вторая гармоника тише основного тона на 12 дБ.
    private static let harmonic = 0.251
    private static let volume: Float = 0.4

    private static let c5 = 523.25
    private static let e5 = 659.25
    private static let g5 = 783.99

    /// C5 → E5 → G5 с шагом 70 мс: ноты звучат по 90 мс, поэтому слегка накладываются.
    static let startWav = wav(frequencies: [c5, e5, g5], step: 0.07)
    /// G5 → C5 с шагом 90 мс — нисходящий ответ на стартовый.
    static let stopWav = wav(frequencies: [g5, c5], step: 0.09)

    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "SoundPlayer")
    private lazy var startPlayer = player(Self.startWav)
    private lazy var stopPlayer = player(Self.stopWav)

    private init() {}

    public func playStart() { restart(startPlayer) }

    public func playStop() { restart(stopPlayer) }

    /// Тот же плеер переиспользуется: повторный старт — с нулевой позиции.
    private func restart(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private func player(_ data: Data) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(data: data)
            player.volume = Self.volume
            player.prepareToPlay()
            return player
        } catch {
            logger.error("Чайм не создан: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Синтез

    static func wav(frequencies: [Double], step: Double) -> Data {
        WavEncoder.encode(mix(frequencies: frequencies, step: step), sampleRate: sampleRate)
    }

    private static func mix(frequencies: [Double], step: Double) -> [Float] {
        let noteLength = Int((attack + decay) * Double(sampleRate))
        let stepLength = Int(step * Double(sampleRate))
        var buffer = [Float](repeating: 0, count: (frequencies.count - 1) * stepLength + noteLength)

        for (index, frequency) in frequencies.enumerated() {
            let offset = index * stepLength
            for sample in 0..<noteLength {
                let time = Double(sample) / Double(sampleRate)
                let wave = sin(2 * .pi * frequency * time) + harmonic * sin(4 * .pi * frequency * time)
                buffer[offset + sample] += Float(wave * envelope(time))
            }
        }

        // Наложение нот складывается — нормируем, иначе кодировщик срежет пики.
        let peak = buffer.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return buffer }
        return buffer.map { $0 / peak * 0.9 }
    }

    /// Линейная атака, затем квадратичный спад ровно в ноль.
    private static func envelope(_ time: Double) -> Double {
        if time < attack { return time / attack }
        let progress = min(1, (time - attack) / decay)
        return (1 - progress) * (1 - progress)
    }
}
