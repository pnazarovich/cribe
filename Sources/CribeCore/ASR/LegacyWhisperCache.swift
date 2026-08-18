import Foundation

/// Модели Whisper, оставшиеся от прежних версий.
///
/// Распознавание держит одна модель — Parakeet, — и веса Whisper на диске больше никому
/// не нужны. Молча их удалить нельзя: это полтора-три гигабайта чужих файлов, и решение
/// об удалении принимает человек. Молча оставить — тоже: он о них не знает и никогда
/// не найдёт папку сам.
///
/// Раскладка досталась от `ModelStore`: `~/Library/Application Support/Cribe/models`.
public struct LegacyWhisperCache: Sendable {
    public static let shared = LegacyWhisperCache(base: defaultBase)

    public static let defaultBase: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cribe", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)

    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    /// Сколько занимают старые веса. Ноль — удалять нечего и спрашивать не о чем.
    ///
    /// Считаем по файлам внутри: `.mlmodelc` — сама по себе папка, и её размер знают
    /// только файлы в ней.
    public func bytesOnDisk() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: keys
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: base.path)
    }

    /// Удаляет папку целиком. Отсутствующая папка — не ошибка: чистить нечего.
    public func remove() throws {
        guard exists() else { return }
        try FileManager.default.removeItem(at: base)
    }
}
