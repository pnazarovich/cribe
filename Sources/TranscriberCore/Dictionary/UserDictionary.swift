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
    private var watcher: DispatchSourceFileSystemObject?

    public private(set) var entries: [DictionaryEntry] {
        get { queue.sync { storage } }
        set { queue.sync { storage = newValue } }
    }

    public var onChange: (@Sendable () -> Void)?

    public init(url: URL) {
        self.url = url
        if let loaded = Self.load(from: url) {
            storage = loaded
        } else {
            // Файла нет — записываем стартовый словарь. Битый JSON не перезаписываем.
            storage = defaultEntries
            if !FileManager.default.fileExists(atPath: url.path) {
                Self.save(defaultEntries, to: url)
            }
        }
        startWatching()
    }

    deinit {
        watcher?.cancel()
    }

    public func replace(entries newEntries: [DictionaryEntry]) {
        entries = newEntries
        Self.save(newEntries, to: url)
        onChange?()
    }

    // MARK: - Диск

    private static func load(from url: URL) -> [DictionaryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([DictionaryEntry].self, from: data)
    }

    private static func save(_ entries: [DictionaryEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - File-watcher

    private func startWatching() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in self?.handleFileEvent() }
        source.setCancelHandler { close(descriptor) }
        watcher = source
        source.resume()
    }

    private func handleFileEvent() {
        // Атомарная запись подменяет inode — переоткрываем дескриптор.
        watcher?.cancel()
        watcher = nil
        startWatching()

        guard let loaded = Self.load(from: url), loaded != entries else { return }
        entries = loaded
        onChange?()
    }
}
