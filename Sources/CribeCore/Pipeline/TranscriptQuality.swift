import Foundation

/// Похоже ли, что распознавание потеряло речь.
///
/// Нужна потому, что потеря молчалива: Whisper не сообщает, что упёрся в бюджет токенов
/// и выбросил хвост окна, — он просто отдаёт текст покороче. Человек узнаёт об этом,
/// только перечитав результат, а записи к тому моменту уже нет.
///
/// Судим грубо и осторожно: единственный сигнал, который есть без второго прохода, — слов
/// на секунду записи. Ложная тревога после каждой диктовки хуже пропущенного редкого случая,
/// поэтому порог заведомо ниже любой живой речи: даже медленный монолог с паузами даёт
/// больше слова в секунду, а 0.4 — это уже «почти всю минуту молчали».
public enum TranscriptQuality {

    /// Ниже этого — точно не живая диктовка целиком.
    static let minimumWordsPerSecond = 0.4
    /// Короче — не судим: «ок» и «да, давай» и есть самый частый способ диктовать.
    static let minimumSeconds: Double = 20

    public static func looksTruncated(words: Int, seconds: Double?) -> Bool {
        guard let seconds, seconds >= minimumSeconds else { return false }
        return Double(words) < seconds * minimumWordsPerSecond
    }

    /// То же самое по готовому тексту — так зовут и конвейер, и окно истории.
    public static func looksTruncated(text: String, seconds: Double?) -> Bool {
        looksTruncated(words: ShortDictation.wordCount(text), seconds: seconds)
    }
}
