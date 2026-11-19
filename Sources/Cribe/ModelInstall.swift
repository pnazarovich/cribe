import Combine
import Foundation
import CribeCore

/// Состояние единственной модели распознавания для UI.
///
/// Загрузка идёт в движке (`ParakeetEngine.prepare`), а показывают её сразу три места:
/// экран загрузки при обновлении, шаг онбординга и строка в настройках. Объект один
/// на приложение — иначе закрытое окно обрывало бы полосу, начатую в нём.
@MainActor
final class ModelInstall: ObservableObject {
    enum State: Equatable {
        case missing
        /// Доля скачанного, 0...1.
        case downloading(Double)
        /// Скачано — идёт компиляция под Neural Engine. Полоса тут стоит на месте,
        /// и показывать её долей значило бы врать.
        case preparing
        case ready
        case failed(String)
    }

    static let shared = ModelInstall(engine: AppCore.shared.engine, settings: AppCore.shared.settings)

    /// Загрузка GigaAM — та же машина состояний, другой движок. Язык у него один.
    static let gigaam = ModelInstall(
        engine: AppCore.shared.gigaam,
        installed: { GigaAMEngine.isInstalled },
        language: { .ru },
        approximateBytes: 850 * 1_000_000
    )

    /// Сколько весит модель. Точную цифру знает только сервер, и до первой загрузки её
    /// неоткуда взять — но человеку перед кнопкой «Скачать» нужен порядок величины,
    /// а не байты.
    static let approximateBytes: Int64 = 600 * 1_000_000

    @Published private(set) var state: State
    /// Сколько займёт на диске — для подписи «Не скачана · ≈…».
    let approximateBytes: Int64

    private let engine: TranscriptionEngine
    private let installed: () -> Bool
    private let language: () -> Language
    private var task: Task<Void, Never>?

    convenience init(engine: ParakeetEngine, settings: AppSettings) {
        self.init(
            engine: engine,
            installed: { ParakeetEngine.isInstalled },
            language: { settings.language },
            approximateBytes: Self.approximateBytes
        )
    }

    init(
        engine: TranscriptionEngine,
        installed: @escaping () -> Bool,
        language: @escaping () -> Language,
        approximateBytes: Int64
    ) {
        self.engine = engine
        self.installed = installed
        self.language = language
        self.approximateBytes = approximateBytes
        state = installed() ? .ready : .missing
    }

    var isReady: Bool { state == .ready }

    /// Перечитать диск. Модель могла доехать мимо этого окна — например, её дотянула
    /// первая диктовка.
    func refresh() {
        guard task == nil else { return }
        if installed(), state != .ready { state = .ready }
    }

    /// Скачать и прогреть. Повторный вызов на идущей загрузке ничего не делает: качать
    /// одно и то же дважды незачем.
    func download() {
        guard task == nil, state != .ready else { return }
        state = installed() ? .preparing : .downloading(0)
        let language = self.language()
        task = Task { [engine] in
            do {
                try await engine.prepare(language: language) { asr in
                    Task { @MainActor [weak self] in self?.apply(asr) }
                }
                await MainActor.run { self.state = .ready }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
            await MainActor.run { self.task = nil }
        }
    }

    /// Остановить загрузку — передумали, выбрали другой движок.
    func cancel() {
        task?.cancel()
        task = nil
        state = installed() ? .ready : .missing
    }

    /// Удалить файлы модели с диска. Звать, когда движок не выбран.
    func remove(at directory: URL) {
        cancel()
        try? FileManager.default.removeItem(at: directory)
        state = installed() ? .ready : .missing
    }

    private func apply(_ asr: ASRModelState) {
        switch asr {
        case .downloading(let fraction): state = .downloading(fraction)
        case .loading: state = .preparing
        case .ready: state = .ready
        // Движок сообщает `notLoaded` на своей ошибке — текст беды придёт следом
        // из `catch`, и затирать им уже показанную причину нельзя.
        case .notLoaded: break
        }
    }
}
