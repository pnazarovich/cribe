import AVFoundation
import Foundation
import OSLog

/// Бэкап последних записей: WAV рядом с историей, кольцом на несколько штук.
///
/// Зачем: распознавание иногда теряет речь, а записи после диктовки не оставалось вовсе —
/// человек говорил минуту, получал «речь не обнаружена», и восстанавливать было нечего.
/// Теперь звук переживает неудачный проход, и из истории его можно распознать заново.
///
/// Приватность важнее удобства: приложение локальное, и голос пачками копиться не должен.
/// Поэтому кольцо короткое (по умолчанию три записи), длина одной ограничена, папка одна
/// и её видно в README, а стереть всё можно одной кнопкой в настройках.
public final class RecordingStore: @unchecked Sendable {
    public static let shared = RecordingStore()

    /// Потолок длины одной записи. Полчаса случайно оставленной записи на диск не лягут:
    /// пять минут 16 кГц mono 16-бит — это 9,6 МБ, а кольцо из трёх даёт предсказуемые
    /// 29 МБ в худшем случае (обычная минутная диктовка — 1,9 МБ).
    public static let maxSeconds: Double = 300

    /// Записи лежат рядом с моделями, в папке приложения.
    public static let defaultFolder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriber/recordings", isDirectory: true)

    /// Где лежат записи. Тестам нужна своя папка — во временной: кольцо и потолок длины
    /// проверяются на настоящих файлах, а трогать записи пользователя прогон не вправе.
    public let folder: URL

    /// Что сохранилось: имя файла для истории и сколько секунд в нём осталось.
    /// Ровно `maxSeconds` означает «запись была длиннее и легла обрезанной» — окно истории
    /// говорит об этом человеку, отдельного флага для одного и того же не нужно.
    public struct Saved: Sendable, Equatable {
        public let name: String
        public let seconds: Double
    }

    private let logger = Logger(subsystem: "online.nazarovych.transcriber", category: "Recordings")
    private let fileManager = FileManager.default

    public init(folder: URL = RecordingStore.defaultFolder) {
        self.folder = folder
    }

    /// Кладёт запись на диск и оставляет в папке только `keeping` самых свежих.
    /// `keeping` ≤ 0 — записи не храним вовсе: папка вычищается, на диск ничего не ложится.
    ///
    /// Возвращает nil при любом сбое: бэкап — страховка, и падать из-за неё конвейер не вправе.
    public func save(_ samples: [Float], keeping: Int) -> Saved? {
        guard keeping > 0 else {
            removeAll()
            return nil
        }
        let limit = AudioCaptureFormat.samples(seconds: Self.maxSeconds)
        let kept = samples.count > limit ? Array(samples[0..<limit]) : samples

        // Имя начинается временем в миллисекундах фиксированной ширины — по нему же идёт
        // сортировка кольца. Хвост случайный: две диктовки подряд могут лечь в одну
        // миллисекунду, и вторая затёрла бы первую.
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).wav"
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try WavEncoder.encode(kept).write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            logger.error("Запись не сохранена: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        prune(keeping: keeping)
        return Saved(name: name, seconds: Double(kept.count) / AudioCaptureFormat.sampleRate)
    }

    /// Путь к сохранённой записи; nil — файла уже нет (вытеснен кольцом или стёрт руками).
    public func url(named name: String) -> URL? {
        let url = folder.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Читает запись обратно в сэмплы 16 кГц mono. Формат наш собственный (`WavEncoder`),
    /// но читаем через AVFoundation: она же приведёт к Float32, если файл вдруг другой.
    public func samples(named name: String) throws -> [Float] {
        guard let url = url(named: name) else { throw RecordingStoreError.missing }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw RecordingStoreError.unreadable
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else { throw RecordingStoreError.unreadable }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    /// Удаляет всё, кроме `keeping` самых свежих записей.
    public func prune(keeping: Int) {
        for url in files().dropFirst(max(0, keeping)) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Убирает одну запись: так отменённая по Esc диктовка не оставляет за собой файл,
    /// до которого нет ни одной двери.
    public func remove(named name: String) {
        guard let url = url(named: name) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Стирает все записи разом — кнопка «стереть» в настройках и путь `keeping == 0`.
    public func removeAll() {
        for url in files() {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Сколько записи занимают на диске.
    public func bytesOnDisk() -> Int64 {
        files().reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
    }

    /// Файлы записей, свежие первыми. Имя — время создания в миллисекундах, поэтому
    /// сортировка по имени и есть сортировка по свежести, и лишнего похода к атрибутам нет.
    private func files() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

public enum RecordingStoreError: LocalizedError {
    case missing
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .missing: return "Записи больше нет — её вытеснили следующие диктовки."
        case .unreadable: return "Запись не читается."
        }
    }
}
