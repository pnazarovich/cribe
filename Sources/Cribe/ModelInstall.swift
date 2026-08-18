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

    /// Сколько весит модель. Точную цифру знает только сервер, и до первой загрузки её
    /// неоткуда взять — но человеку перед кнопкой «Скачать» нужен порядок величины,
    /// а не байты.
    static let approximateBytes: Int64 = 600 * 1_000_000

    @Published private(set) var state: State

    private let engine: ParakeetEngine
    private let settings: AppSettings
    private var task: Task<Void, Never>?

    init(engine: ParakeetEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        state = ParakeetEngine.isInstalled ? .ready : .missing
    }

    var isReady: Bool { state == .ready }

    /// Перечитать диск. Модель могла доехать мимо этого окна — например, её дотянула
    /// первая диктовка.
    func refresh() {
        guard task == nil else { return }
        if ParakeetEngine.isInstalled, state != .ready { state = .ready }
    }

    /// Скачать и прогреть. Повторный вызов на идущей загрузке ничего не делает: качать
    /// одно и то же дважды незачем.
    func download() {
        guard task == nil, state != .ready else { return }
        state = ParakeetEngine.isInstalled ? .preparing : .downloading(0)
        task = Task { [engine, settings] in
            do {
                try await engine.prepare(language: settings.language) { asr in
                    Task { @MainActor [weak self] in self?.apply(asr) }
                }
                await MainActor.run { self.state = .ready }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
            await MainActor.run { self.task = nil }
        }
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
