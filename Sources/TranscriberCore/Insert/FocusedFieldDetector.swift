import ApplicationServices

/// Есть ли прямо сейчас поле, в которое осмысленно вставлять текст.
public enum FocusState: Sendable, Equatable {
    case editable
    case notEditable
    /// Судить не о чем: разрешения нет, AX выключен или приложение не ответило.
    case unknown
}

/// Сырой ответ AX-слоя о сфокусированном элементе. Отдельный тип — это шов: раскладка
/// «что ответила система → вердикт» проверяется тестами, ни разу не трогая живой AX.
public enum FocusedElementProbe: Sendable, Equatable {
    /// AX недоступен: нет разрешения, API выключен, приложение не отвечает.
    case unavailable
    /// Фокуса нет вовсе — ни поля, ни любого другого элемента.
    case noFocus
    /// `valueSettable` — можно ли записать `AXValue`; `hasSelectedTextRange` — отдаёт ли
    /// элемент выделение текстом. Веб- и Electron-поля часто узнаются только по второму.
    case element(role: String?, valueSettable: Bool, hasSelectedTextRange: Bool)
}

/// Проверка «а есть ли куда вставлять» перед синтетическим Cmd-V.
///
/// Железное правило: сомнение трактуется в пользу вставки. Пропущенное поле ввода — это
/// текст, уехавший в карточку вместо документа (неприятно, но всё на месте); ошибочная
/// уверенность в обратную сторону — это Cmd-V в чужое окно, где он может сработать как
/// команда. Поэтому всё, что не разобрали, — `.unknown`, а `.unknown` вставляется как раньше.
public enum FocusedFieldDetector {
    /// Роли, которые сами по себе означают поле ввода. `AXSearchField` формально сабролью,
    /// но часть приложений отдаёт её именно ролью — держим обе трактовки.
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]

    /// Сколько ждём ответа от чужого приложения. Зависшее приложение не должно задерживать
    /// вставку: молчание — это `.unknown`, то есть обычный Cmd-V.
    private static let messagingTimeout: Float = 0.25

    /// Вердикт по живой системе. Блокирующий вызов (ходит в чужой процесс) — звать с фона.
    public static func current() -> FocusState {
        classify(systemProbe())
    }

    /// Чистая функция: весь смысл детектора живёт здесь и целиком покрыт тестами.
    public static func classify(_ probe: FocusedElementProbe) -> FocusState {
        switch probe {
        case .unavailable:
            return .unknown
        case .noFocus:
            return .notEditable
        case .element(let role, let valueSettable, let hasSelectedTextRange):
            if let role, editableRoles.contains(role) { return .editable }
            // Роль незнакомая, но элемент ведёт себя как текстовое поле — этого достаточно.
            return valueSettable || hasSelectedTextRange ? .editable : .notEditable
        }
    }

    private static func systemProbe() -> FocusedElementProbe {
        // Разрешение то же, что у вставки: без него системный элемент отдаёт `.apiDisabled`,
        // но спрашивать систему ради заведомо неизвестного ответа незачем.
        guard AXIsProcessTrusted() else { return .unavailable }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        switch status {
        case .success:
            break
        // Фокуса действительно нет: рабочий стол, окно без полей, картинка на весь экран.
        case .noValue, .attributeUnsupported:
            return .noFocus
        // Всё остальное (API выключен, приложение зависло, элемент протух) — не наше дело.
        default:
            return .unavailable
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unavailable }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement

        var roleValue: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success
            ? roleValue as? String
            : nil

        var settable: DarwinBoolean = false
        let valueSettable =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue

        var range: CFTypeRef?
        let hasSelectedTextRange = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &range
        ) == .success

        return .element(
            role: role,
            valueSettable: valueSettable,
            hasSelectedTextRange: hasSelectedTextRange
        )
    }
}
