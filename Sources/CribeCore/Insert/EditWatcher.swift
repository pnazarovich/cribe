import ApplicationServices
import Foundation
import OSLog

/// Доступ к содержимому поля, в которое только что вставили текст. Живая реализация ходит
/// в Accessibility; тестам нужен двойник — прогон не имеет права лазить в чужие окна.
public struct FieldAccess: Sendable {
    /// Сфокусированный элемент прямо сейчас, чем бы он ни был.
    public var focused: @Sendable () -> AnyObject?
    /// Текст этого элемента. `nil` — элемента больше нет, приложение закрылось или молчит.
    public var text: @Sendable (AnyObject) -> String?

    public init(
        focused: @escaping @Sendable () -> AnyObject?,
        text: @escaping @Sendable (AnyObject) -> String?
    ) {
        self.focused = focused
        self.text = text
    }

    public static let system = FieldAccess(
        focused: { EditWatcher.systemFocusedElement() },
        text: { EditWatcher.systemText(of: $0) }
    )
}

/// Смотрит, что человек поправил в только что вставленном тексте.
///
/// Порядок такой: вставили → выждали, пока приложение-приёмник действительно примет текст,
/// → сняли слепок поля → позже сняли второй и сравнили. Разница и есть правки.
///
/// Работает не везде, и это честное ограничение приёма: поле обязано отдавать своё
/// содержимое через Accessibility. Нативные приложения и большинство редакторов отдают,
/// часть Electron — нет. Там, где не отдаёт, приём просто молчит: словарь не пополняется,
/// но и не портится.
public final class EditWatcher: @unchecked Sendable {
    public static let shared = EditWatcher()

    /// Сколько ждать, прежде чем снимать точку отсчёта. Cmd-V асинхронный: сразу после
    /// отправки события поле ещё пустое, и снимок поймал бы состояние ДО вставки.
    /// Полсекунды хватает нативным приложениям с большим запасом.
    static let settleDelay: TimeInterval = 0.5

    /// Через сколько снимать второй слепок. Правят обычно сразу — перечитал, поправил
    /// слово, пошёл дальше. Слишком долго ждать нельзя: человек уйдёт в другое поле,
    /// и элемент протухнет.
    static let readbackDelay: TimeInterval = 20

    private let access: FieldAccess
    private let queue = DispatchQueue(label: "online.nazarovych.cribe.edits")
    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Edits")

    /// Элемент, слепок и то, что мы туда вставили. Всё трогается только на `queue`.
    private var element: AnyObject?
    private var baseline: String?
    private var inserted: String?

    public init(access: FieldAccess = .system) {
        self.access = access
    }

    /// Взять поле под наблюдение сразу после удачной вставки.
    ///
    /// Предыдущее наблюдение при этом закрывается: если человек надиктовал второй раз,
    /// первый текст он уже либо поправил, либо нет, и ждать дольше нечего.
    public func watch(inserted text: String, then handle: @escaping @Sendable ([Correction]) -> Void) {
        collect(handle)
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { [self] in
            guard let field = access.focused(), let value = access.text(field) else { return }
            guard let point = Self.baseline(value: value, inserted: text) else {
                // Вставленного текста в поле нет: либо оно не отдаёт содержимое, либо текст
                // уехал не туда. Наблюдать не за чем.
                Self.logger.debug("вставленного текста в поле не видно — наблюдение не начато")
                return
            }
            element = field
            baseline = point
            inserted = text
            queue.asyncAfter(deadline: .now() + Self.readbackDelay) { [self] in
                collect(handle)
            }
        }
    }

    /// Снять второй слепок и отдать правки. Наблюдение после этого закрывается.
    public func collect(_ handle: @escaping @Sendable ([Correction]) -> Void) {
        queue.async { [self] in
            guard let field = element, let before = baseline, let text = inserted else { return }
            element = nil
            baseline = nil
            inserted = nil

            guard let after = access.text(field), after != before else { return }
            let corrections = EditDiff.corrections(before: before, after: after, inserted: text)
            guard !corrections.isEmpty else { return }
            Self.logger.debug("замечено правок: \(corrections.count, privacy: .public)")
            handle(corrections)
        }
    }

    /// Годится ли снимок поля точкой отсчёта. Единственная проверка: вставленный текст
    /// обязан быть в поле виден. Иначе сравнивать нечего — и, что важнее, любая правка
    /// «до» и «после» была бы приписана нам без всяких оснований.
    static func baseline(value: String, inserted: String) -> String? {
        let text = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, value.contains(text) else { return nil }
        return value
    }
}

// MARK: - Живой Accessibility

extension EditWatcher {
    /// Тот же таймаут, что у детектора поля: чужое приложение не имеет права нас держать.
    private static let messagingTimeout: Float = 0.25

    static func systemFocusedElement() -> AnyObject? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
            let focused,
            CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return focused
    }

    static func systemText(of element: AnyObject) -> String? {
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let field = element as! AXUIElement
        AXUIElementSetMessagingTimeout(field, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
