import Foundation

/// Словарь на диске: JSON, редактируемый и в приложении, и любым редактором
/// (file-watcher перечитывает). Доступ к записям сериализован через DispatchQueue.
public final class UserDictionary: @unchecked Sendable {
    public static let defaultURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Transcriber/dictionary.json")

    private let url: URL
    private let queue = DispatchQueue(label: "online.nazarovych.transcriber.dictionary")
    private let watchQueue = DispatchQueue(label: "online.nazarovych.transcriber.dictionary.watch")
    private var storage: [DictionaryEntry]
    private var isSaving = false
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?

    public private(set) var entries: [DictionaryEntry] {
        get { queue.sync { storage } }
        set { queue.sync { storage = newValue } }
    }

    /// Ошибка последней записи на диск (nil — записалось). Замены в памяти
    /// применяются в любом случае, но UI должен уметь показать, что файл не сохранён.
    public private(set) var lastSaveError: Error?

    public var onChange: (@Sendable () -> Void)?

    public init(url: URL) {
        self.url = url
        if let loaded = Self.load(from: url) {
            storage = loaded
        } else {
            // Файла нет — записываем стартовый словарь. Битый JSON не перезаписываем.
            storage = defaultEntries
            if !FileManager.default.fileExists(atPath: url.path) {
                save(defaultEntries)
            }
        }
        startWatching()
    }

    deinit {
        directoryWatcher?.cancel()
        fileWatcher?.cancel()
    }

    public func replace(entries newEntries: [DictionaryEntry]) {
        entries = newEntries
        save(newEntries)
        onChange?()
    }

    // MARK: - Диск

    private static func load(from url: URL) -> [DictionaryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([DictionaryEntry].self, from: data)
    }

    private func save(_ entries: [DictionaryEntry]) {
        // Атомарная запись сначала создаёт временный файл — это событие каталога,
        // на котором dictionary.json ещё старый. Перечитывать его в этот момент
        // означало бы откатить память к устаревшему содержимому.
        queue.sync { isSaving = true }
        defer { queue.sync { isSaving = false } }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error
            FileHandle.standardError.write(
                Data("UserDictionary: не удалось сохранить \(url.path): \(error)\n".utf8)
            )
        }
    }

    // MARK: - File-watcher

    private func startWatching() {
        // Каталог: его inode стабилен, поэтому слежение переживает и атомарную
        // подмену файла, и delete-then-write у редакторов.
        directoryWatcher = makeSource(path: url.deletingLastPathComponent().path) { [weak self] in
            self?.rearmFileWatcher()
            self?.reloadFromDisk()
        }
        rearmFileWatcher()
    }

    /// Отдельный источник на сам файл: правка «на месте» каталог не меняет.
    /// Дескриптор переоткрывается на каждом событии каталога — после подмены inode старый мёртв.
    private func rearmFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = makeSource(path: url.path) { [weak self] in self?.reloadFromDisk() }
    }

    private func makeSource(
        path: String,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: watchQueue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func reloadFromDisk() {
        let (busy, current) = queue.sync { (isSaving, storage) }
        guard !busy, let loaded = Self.load(from: url), loaded != current else { return }
        entries = loaded
        onChange?()
    }
}
