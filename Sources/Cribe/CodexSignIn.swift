import AppKit
import SwiftUI
import CribeCore

/// Device-code вход в ChatGPT: старт, ожидание подтверждения, статус. Держит одну задачу
/// поллинга — вторая заявка отменяет первую.
///
/// В `SettingsView` живёт своя приватная копия этой же механики (`CodexAuthModel`).
/// Разъехаться им нельзя, и объединить их надо — но файл настроек прямо сейчас правит
/// соседний раунд, поэтому вход первого запуска вынесен сюда отдельно; свести обе точки
/// на этот класс — отдельная уборка, ровно одна замена типа в `SettingsView`.
@MainActor
final class CodexSignInModel: ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var session: DeviceFlowSession?
    @Published private(set) var isPolling = false
    @Published private(set) var message: String?

    private var task: Task<Void, Never>?
    /// Номер попытки входа: хвост отменённой задачи не должен трогать состояние следующей.
    private var generation = 0

    func refreshStatus() async {
        isAuthorized = await CodexAuth.shared.isAuthorized()
    }

    func start() {
        cancel()
        message = nil
        let generation = self.generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await CodexAuth.shared.startDeviceFlow()
                guard generation == self.generation else { return }
                self.session = session
                isPolling = true

                try await CodexAuth.shared.pollUntilAuthorized(session)
                guard generation == self.generation else { return }
                isAuthorized = true
                message = nil
            } catch {
                guard generation == self.generation else { return }
                // deviceCodeDisabled сам объясняет, что включить в настройках ChatGPT.
                message = Self.isCancellation(error) ? nil : error.localizedDescription
            }
            guard generation == self.generation else { return }
            session = nil
            isPolling = false
        }
    }

    /// Идемпотентна: повторный вызов на уже остановленном входе ничего не меняет.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        session = nil
        isPolling = false
    }

    /// Отмена — не ошибка: `Task` бросает `CancellationError`, URLSession — `URLError.cancelled`.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
