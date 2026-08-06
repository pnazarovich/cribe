import Foundation
import CribeCore

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

/// Загрузка моделей распознавания — модель за моделью. Один объект на приложение: настройки и
/// онбординг показывают одно и то же состояние, и кнопка «Скачать» в одном окне видна в другом.
/// Состояние читается с диска, поэтому уже скачанная модель сразу показывается установленной.
///
/// Считаем моделями, а не языками: русский и английский делят одну turbo. Показывать её двумя
/// строками значило бы обещать вторые 1,5 ГБ, которых не будет, а удалять по языку — стирать
/// файлы из-под соседнего языка.
@MainActor
final class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()

    /// Ключ — вариант модели (`ModelBundle.variant`), а не язык.
    @Published private(set) var states: [String: ModelDownloadState] = [:]

    private let store: ModelStore
    /// Идущие загрузки: одна на модель. Отмена — отмена этой задачи.
    private var tasks: [String: Task<Void, Never>] = [:]

    init(store: ModelStore = .shared) {
        self.store = store
        refresh()
    }

    func state(of bundle: ModelBundle) -> ModelDownloadState {
        states[bundle.variant] ?? .missing
    }

    /// Состояние модели, на которой работает язык: у русского и английского оно одно.
    func state(of language: Language) -> ModelDownloadState {
        state(of: ModelBundle.bundle(for: language))
    }

    /// Сколько модель весит примерно — до скачивания фактического размера ещё нет.
    static func approximateBytes(for bundle: ModelBundle) -> Int64 {
        Int64(bundle.sizeGB * 1_000_000_000)
    }

    /// Перечитывает диск. Идущую загрузку не трогает: у неё состояние свежее любого диска.
    func refresh() {
        for bundle in ModelBundle.all {
            if case .downloading = states[bundle.variant] { continue }
            states[bundle.variant] = diskState(bundle)
        }
    }

    /// Качает модель. Повторный вызов на идущей загрузке ничего не начинает,
    /// уже скачанную модель движок пропускает сам.
    func download(_ bundle: ModelBundle, engine: WhisperEngine) async {
        guard tasks[bundle.variant] == nil else { return }

        states[bundle.variant] = .downloading(0)
        let task = Task { [weak self] in
            do {
                try await engine.download(language: bundle.primaryLanguage) { fraction in
                    // Прогресс приходит из фонового потока — состояние живёт на главном.
                    Task { @MainActor in self?.setProgress(fraction, for: bundle) }
                }
            } catch is CancellationError {
                // Отмена — не ошибка: итог всё равно сверяется с диском.
            } catch {
                self?.states[bundle.variant] = .failed(error.localizedDescription)
            }
        }
        tasks[bundle.variant] = task

        await task.value
        tasks[bundle.variant] = nil
        // Оборванная загрузка оставляет папку недокачанной — что вышло, знает только диск.
        if case .failed = states[bundle.variant] { return }
        states[bundle.variant] = diskState(bundle)
    }

    func cancel(_ bundle: ModelBundle) {
        tasks[bundle.variant]?.cancel()
    }

    /// Убирает модель с диска — вместе со всеми языками, которые на ней работают.
    /// Сначала выгружаем прогретый инстанс: стирать файлы под живой моделью нельзя.
    func remove(_ bundle: ModelBundle, engine: WhisperEngine) throws {
        cancel(bundle)
        engine.unload(language: bundle.primaryLanguage)
        try store.remove(variant: bundle.variant)
        states[bundle.variant] = diskState(bundle)
    }

    private func setProgress(_ fraction: Double, for bundle: ModelBundle) {
        // Загрузку уже отменили или она уже кончилась — прогресс опоздал.
        guard case .downloading = states[bundle.variant] else { return }
        states[bundle.variant] = .downloading(min(max(fraction, 0), 1))
    }

    private func diskState(_ bundle: ModelBundle) -> ModelDownloadState {
        store.isInstalled(variant: bundle.variant)
            ? .installed(bytes: store.sizeOnDisk(variant: bundle.variant))
            : .missing
    }
}
