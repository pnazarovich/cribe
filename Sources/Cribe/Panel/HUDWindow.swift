import AppKit
import OSLog

/// Общий рецепт окна HUD: и пилюля, и карточки обязаны появляться поверх ЧУЖОГО
/// полноэкранного пространства — там пользователь и живёт.
///
/// Рецепт проверен пробой на живой системе (2026-08-02, полноэкранные Chrome, cmux и
/// Claude): семь сочетаний яруса и поведения — `.statusBar`, `.screenSaver`, `.popUpMenu`,
/// щит минус один, с `.stationary` и без, `.moveToActiveSpace` вместо `.canJoinAllSpaces` —
/// показываются над полным экраном ОДИНАКОВО хорошо. То есть дело было не в рецепте.
///
/// Дело было в том, что рецепт со временем перестаёт действовать. Замерено на боевом
/// процессе, прожившем сорок минут: во время живой записи окно пилюли (ярус 25, тот самый
/// `collectionBehavior`) не появлялось ни на одном полноэкранном пространстве, оставаясь
/// на рабочем столе, и ехало вместе с переключением пространств — то есть вело себя как
/// окно, ПРИВЯЗАННОЕ к пространству. Свежий процесс той же сборки в тот же момент
/// показывал ту же панель поверх того же полного экрана без единой осечки.
///
/// Отсюда правило: членство во всех пространствах — не настройка «один раз при создании»,
/// а заявка, которую подтверждают на каждом показе. Стоит она наносекунды.
@MainActor
enum HUDWindow {
    /// Ярус HUD: `.floating` (3) перекрывается полноэкранным видео и презентациями,
    /// `.statusBar` (25) — нет.
    static let level: NSWindow.Level = .statusBar

    /// `.canJoinAllSpaces` — окно на всех пространствах, включая чужие полноэкранные;
    /// `.fullScreenAuxiliary` — разрешение показываться рядом с полноэкранным окном.
    static let spaceBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Panel")

    /// Показ с подтверждением заявки. `extra` — добавка к общему поведению (пилюля просит
    /// ещё `.stationary`, чтобы не разъезжаться с окнами на Mission Control).
    ///
    /// Именно `orderFrontRegardless`: `makeKey` увёл бы фокус с целевого поля ввода.
    static func orderFront(_ window: NSWindow, extra: NSWindow.CollectionBehavior = []) {
        window.collectionBehavior = spaceBehavior.union(extra)
        window.orderFrontRegardless()
        // Страховка на один тик: если окно всё же осталось на другом пространстве, заявку
        // пересобираем с нуля и просим ещё раз. Один раз, без цикла — это подпорка, а не
        // механизм, и в лог она пишет именно потому, что случаться не должна.
        Task { @MainActor in
            guard window.isVisible, !window.isOnActiveSpace else { return }
            window.collectionBehavior = []
            window.collectionBehavior = spaceBehavior.union(extra)
            window.orderFrontRegardless()
            logger.notice("Окно HUD осталось на чужом пространстве — заявка переподана")
        }
    }
}
