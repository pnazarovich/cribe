import Foundation
import OSLog

/// Переезд данных из-под старого имени продукта (Transcriber → Cribe, август 2026).
///
/// Под старым именем в `~/Library/Application Support/Transcriber` лежат скачанные модели
/// (гигабайты), словарь и записи, а в домене настроек `online.nazarovych.transcriber` —
/// хоткеи, язык и выбранный микрофон. Приложение с новым именем смотрит в новые места и без
/// переезда увидело бы пустоту: предложило бы скачать модели заново и завело бы настройки
/// с нуля.
///
/// Переезд разовый: источник после него исчезает, поэтому повторный запуск ничего не делает.
public enum LegacyRename {
    /// Папка данных старого имени в `~/Library/Application Support`.
    public static let oldFolderName = "Transcriber"
    public static let newFolderName = "Cribe"
    /// Домен настроек — это старый идентификатор бандла (файл `~/Library/Preferences/<домен>.plist`).
    public static let oldDefaultsDomain = "online.nazarovych.transcriber"

    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Migration")

    /// Зовётся один раз на старте ПРИЛОЖЕНИЯ — до первого чтения настроек и моделей.
    /// Именно приложения: у CLI свой домен `UserDefaults.standard`, и настройки владельца
    /// уехали бы не туда.
    public static func run() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        migrateFolder(
            from: support.appendingPathComponent(oldFolderName, isDirectory: true),
            to: support.appendingPathComponent(newFolderName, isDirectory: true)
        )
        migrateDefaults(from: oldDefaultsDomain, into: .standard)
    }

    /// Переносит папку данных целиком. Старой нет — переезжать нечему; новая уже есть —
    /// не трогаем: сливать два хранилища некому, а свежее важнее старого.
    @discardableResult
    public static func migrateFolder(
        from old: URL,
        to new: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: old.path) else { return false }
        guard !fileManager.fileExists(atPath: new.path) else { return false }
        do {
            try fileManager.moveItem(at: old, to: new)
        } catch {
            logger.error("Данные не переехали: \(error.localizedDescription, privacy: .public)")
            return false
        }
        logger.notice("Данные переехали: \(old.path, privacy: .public) → \(new.path, privacy: .public)")
        return true
    }

    /// Переносит значения старого домена настроек в текущий. Ключ, который в новом домене уже
    /// есть, не трогаем — записанное новым запуском старее не становится. Источник стираем:
    /// иначе удалённая настройка воскресала бы на следующем запуске.
    @discardableResult
    public static func migrateDefaults(from domain: String, into defaults: UserDefaults) -> Bool {
        guard let old = defaults.persistentDomain(forName: domain), !old.isEmpty else { return false }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.removePersistentDomain(forName: domain)
        logger.notice("Настройки переехали из домена \(domain, privacy: .public): ключей — \(old.count)")
        return true
    }
}
