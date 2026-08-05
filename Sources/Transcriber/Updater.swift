import AppKit
import Combine
import Sparkle

/// Автообновление на Sparkle 2.
///
/// Приложение живёт в строке состояния (`LSUIElement`), и от этого зависит, как показывать
/// найденное обновление. Путей ровно два, и ведут они себя по-разному.
///
/// Проверку, которую запустил человек (пункт меню), Sparkle показывает сама и сама же
/// выводит приложение вперёд: её стандартный драйвер видит фоновое приложение
/// (`.accessory`) и зовёт `activateIgnoringOtherApps:` перед тем, как открыть окно.
/// Рецепт `WindowPresenter` здесь не нужен и даже вреден: окно не сцена SwiftUI, ждать
/// его появления и поднимать вручную нечего, а политику активации Sparkle не трогает.
///
/// А вот ПЛАНОВУЮ проверку (раз в сутки) Sparkle фоновому приложению показывает без
/// активации — окно всплыло бы ровно так, как всплывать не должно: позади чужих окон.
/// Sparkle про это знает и сама пишет в журнал, что фоновому приложению положены «мягкие
/// напоминания». Мы их и делаем: плановую находку перехватываем и превращаем в тихую
/// строку меню. Пока её не нажали, на экран ничего не лезет; нажатие идёт уже по пути
/// «проверил пользователь» — с активацией и окном поверх всего.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    /// Версия, которую нашла плановая проверка. Пока не `nil` — в меню висит напоминание.
    @Published private(set) var pendingVersion: String?

    /// Пока проверка идёт, второй запуск ничего не сделает: на это гасится пункт меню.
    @Published private(set) var canCheck = false

    /// Тумблер «Проверять обновления автоматически».
    ///
    /// Своего флага в `AppSettings` намеренно нет: состояние хранит сама Sparkle, а
    /// `SUEnableAutomaticChecks` в Info.plist — только значение по умолчанию для тех, кто
    /// ещё ничего не выбирал. Второй флаг рядом разошёлся бы с ним при первой же правке.
    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Драйвер получает делегата в момент создания, поэтому контроллер собирается лениво —
    /// после `super.init()`, когда на `self` уже можно ссылаться.
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: self
    )

    private var updater: SPUUpdater { controller.updater }

    private var canCheckObservation: AnyCancellable?

    override private init() {
        super.init()
    }

    /// Запуск после старта NSApplication — как у панели и хоткеев: до этого момента
    /// расписание проверок заводить не на чем.
    func start() {
        guard canCheckObservation == nil else { return }
        controller.startUpdater()
        // `canCheckForUpdates` — KVO-свойство Sparkle; подписка отдаёт и текущее значение.
        canCheckObservation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheck = value }
            }
    }

    /// Проверка «от пользователя»: этот путь Sparkle показывает с активацией приложения.
    /// Он же гасит напоминание — Sparkle сообщит об этом через делегата.
    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// Мягкие напоминания для менюбар-приложения: см. комментарий к классу.
extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `immediateFocus` — редкий случай, когда Sparkle и так покажет окно в фокусе
    /// (например, обновление нашлось сразу после запуска). Тогда пусть показывает сама;
    /// во всех остальных плановых случаях показываем мы — строкой в меню.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Показывает Sparkle — напоминать нечего, окно и так перед глазами.
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { self.pendingVersion = version }
    }

    /// Человек до обновления добрался — напоминание своё отработало.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { self.pendingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { self.pendingVersion = nil }
    }
}
