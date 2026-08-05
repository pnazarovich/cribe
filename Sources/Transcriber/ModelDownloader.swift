import Foundation
import TranscriberCore

/// Что с моделью языка прямо сейчас.
enum ModelDownloadState: Equatable {
    /// На диске её нет — первая диктовка на этом языке начнётся с загрузки.
    case missing
    /// Доля скачанного, 0...1.
    case downloading(Double)
    /// Скачана целиком; байты — фактический размер папки.
    case installed(bytes: Int64)
    case failed(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Загрузка моделей распознавания — язык за языком. Один объект на приложение: настройки и
/// онбординг показывают одно и то же состояние, и кнопка «Скачать» в одном окне видна в другом.
/// Состояние читается с диска, поэтому уже скачанный язык сразу показывается установленным.
@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    @Published private(set) var states: [Language: ModelDownloadState] = [:]

    private let store: ModelStore
    /// Идущие загрузки: одна на язык. Отмена — отмена этой задачи.
    private var tasks: [Language: Task<Void, Never>] = [:]

    init(store: ModelStore = .shared) {
        self.store = store
        refresh()
    }

    /// Сколько модель весит примерно — до скачивания фактического размера ещё нет.
    /// Русский обслуживает turbo, украинский — large-v3, отсюда и разница почти вдвое.
    static func approximateBytes(for language: Language) -> Int64 {
        language == .ru ? 1_500_000_000 : 2_900_000_000
    }

    /// Перечитывает диск. Идущую загрузку не трогает: у неё состояние свежее любого диска.
    func refresh() {
        for language in Language.allCases {
            if case .downloading = states[language] { continue }
            states[language] = diskState(language)
        }
    }

    /// Качает модель языка. Повторный вызов на идущей загрузке ничего не начинает,
    /// уже скачанный язык движок пропускает сам.
    func download(_ language: Language, engine: WhisperEngine) async {
        guard tasks[language] == nil else { return }

        states[language] = .downloading(0)
        let task = Task { [weak self] in
            do {
                try await engine.download(language: language) { fraction in
                    // Прогресс приходит из фонового потока — состояние живёт на главном.
                    Task { @MainActor in self?.setProgress(fraction, for: language) }
                }
            } catch is CancellationError {
                // Отмена — не ошибка: итог всё равно сверяется с диском.
            } catch {
                self?.states[language] = .failed(error.localizedDescription)
            }
        }
        tasks[language] = task

        await task.value
        tasks[language] = nil
        // Оборванная загрузка оставляет папку недокачанной — что вышло, знает только диск.
        if case .failed = states[language] { return }
        states[language] = diskState(language)
    }

    func cancel(_ language: Language) {
        tasks[language]?.cancel()
    }

    /// Убирает модель языка с диска. Сначала выгружаем прогретый инстанс: стирать файлы
    /// под живой моделью нельзя.
    func remove(_ language: Language, engine: WhisperEngine) throws {
        cancel(language)
        engine.unload(language: language)
        try store.remove(variant: language.whisperModel)
        states[language] = diskState(language)
    }

    private func setProgress(_ fraction: Double, for language: Language) {
        // Загрузку уже отменили или она уже кончилась — прогресс опоздал.
        guard case .downloading = states[language] else { return }
        states[language] = .downloading(min(max(fraction, 0), 1))
    }

    private func diskState(_ language: Language) -> ModelDownloadState {
        let variant = language.whisperModel
        return store.isInstalled(variant: variant)
            ? .installed(bytes: store.sizeOnDisk(variant: variant))
            : .missing
    }
}
