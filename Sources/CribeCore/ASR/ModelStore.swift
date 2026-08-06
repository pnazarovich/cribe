import Foundation

/// Модели Whisper на диске: где лежат, скачаны ли целиком, сколько занимают и как их убрать.
/// Одно место на всё приложение: движок берёт отсюда папку для WhisperKit, настройки — размер
/// и удаление. Раскладка HubApi: `<base>/models/argmaxinc/whisperkit-coreml/<variant>`.
public struct ModelStore: Sendable {
    /// Модели и токенайзеры лежат в ~/Library/Application Support/Cribe/models.
    public static let defaultBase: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cribe", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)

    /// Хранилище приложения. Тестам нужна своя база — во временной папке.
    public static let shared = ModelStore(base: defaultBase)

    /// Корень загрузок: его же WhisperKit принимает как `downloadBase` и `tokenizerFolder`.
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// Папка варианта — существует она или нет.
    public func folder(variant: String) -> URL {
        base
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// Папка скачанной модели, если она на месте целиком. Иначе nil — тогда идём в сеть.
    public func installedFolder(variant: String) -> URL? {
        let folder = folder(variant: variant)

        // Те же три модели проверяет WhisperKit при загрузке; недокачанную папку не принимаем.
        let required = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let complete = required.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).\(ext)").path)
            }
        }
        return complete ? folder : nil
    }

    public func isInstalled(variant: String) -> Bool {
        installedFolder(variant: variant) != nil
    }

    /// Сколько занимает вариант на диске. Папки нет — 0. Считаем по файлам внутри:
    /// `.mlmodelc` — сама по себе папка, и её размер знают только файлы в ней.
    public func sizeOnDisk(variant: String) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: folder(variant: variant),
            includingPropertiesForKeys: keys
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Убирает вариант с диска. Папки нет — ничего не делает: удаление идемпотентно.
    public func remove(variant: String) throws {
        let folder = folder(variant: variant)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }
}
