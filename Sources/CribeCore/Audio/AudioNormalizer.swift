import Accelerate
import Foundation

/// Приведение уровня записи к рабочему для распознавания.
///
/// Зачем: громкость входа в системе — величина, о которой человек не думает. У встроенного
/// микрофона MacBook она бывает выставлена на 47 из 100, и запись выходит вдвое тише
/// возможного. Ворота речи (Silero) такую запись переживают — замер показал, что они находят
/// всю речь даже при пике 0.023 (−33 dBFS). А вот Whisper на тихом звуке разваливается:
/// на одной и той же фикстуре (114 c быстрой русской речи) при пике 0.75 распознаётся
/// 266 слов, при 0.047 — 166, при 0.023 — 57. Это и есть «распозналась только небольшая
/// часть» на ровном месте.
///
/// Как: пиковая нормализация всей записи одним множителем. Не RMS — целевой RMS пришлось бы
/// подбирать под манеру говорить, а пик даёт предсказуемый запас до клиппинга и не трогает
/// динамику. Один множитель на весь буфер: разное усиление у соседних кусков означало бы,
/// что подтверждённая фоном часть и хвост распознаны по-разному.
public enum AudioNormalizer {

    /// Целевой пик — −1 dBFS. Не 0 dBFS: запас на то, что ресемплер и кодирование в WAV
    /// могут дать выброс чуть выше исходного пика.
    static let targetPeak: Float = 0.891

    /// Потолок усиления — 20× (+26 dB). Без него шум вентилятора в паузах раскачался бы
    /// до уровня речи, и ворота начали бы срабатывать на пустоте. Что этого хватает,
    /// видно по замеру: с потолком 20× запись, ослабленная в 32 раза, поднимается до пика
    /// 0.47 — там Whisper уже работает в полную силу.
    static let maxGain: Float = 20

    /// Ниже этого усиление не считаем вовсе: запись и так на уровне, а лишний проход
    /// по мегабайтам буфера ничего не даёт.
    static let minGain: Float = 1.2

    /// Множитель, которым надо умножить запись с таким пиком. 1 — не трогать.
    ///
    /// Тише порога тишины — тоже 1: там не тихая речь, а мёртвый вход, и усиливать нечего.
    /// Порог общий с `CaptureRecorder` (`AudioCaptureFormat.silenceThreshold`).
    public static func gain(forPeak peak: Float) -> Float {
        guard peak >= AudioCaptureFormat.silenceThreshold else { return 1 }
        let wanted = min(targetPeak / peak, maxGain)
        return wanted < minGain ? 1 : wanted
    }

    /// Пик буфера по модулю.
    public static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_maxmgv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    /// Нормализованная копия. Усиливать нечего — возвращает исходный буфер без копии.
    public static func normalized(_ samples: [Float]) -> [Float] {
        var factor = gain(forPeak: peak(samples))
        guard factor > 1 else { return samples }

        var result = [Float](repeating: 0, count: samples.count)
        vDSP_vsmul(samples, 1, &factor, &result, 1, vDSP_Length(samples.count))
        return result
    }
}
