import AppKit
import ApplicationServices
import Carbon

/// Результат попытки вставки текста в активное приложение.
public enum InsertOutcome: Sendable {
    case pasted
    case clipboardOnly(reason: String)
}

/// Вставка текста в фронтмост-приложение: буфер обмена + синтетический Cmd-V.
///
/// Политика спеки: текст ОСТАЁТСЯ в буфере обмена — снапшот и восстановление
/// предыдущего содержимого намеренно не делаются.
public enum TextInserter {
    /// Выдано ли приложению разрешение Accessibility (нужно для синтеза Cmd-V).
    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Показать системный запрос на выдачу Accessibility.
    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Только буфер обмена, без Cmd-V: этим же путём текст уходит в карточку и в пункты меню.
    public static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    public static func insert(_ text: String) -> InsertOutcome {
        copy(text)

        // Парольные поля перехватывают ввод — синтетический Cmd-V до них не дойдёт.
        if IsSecureEventInputEnabled() {
            return .clipboardOnly(reason: "secure input")
        }
        guard hasAccessibility else {
            return .clipboardOnly(reason: "no accessibility")
        }

        Thread.sleep(forTimeInterval: pasteboardSettleDelay)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        else {
            return .clipboardOnly(reason: "cgevent unavailable")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return .pasted
    }

    /// Заменить содержимое поля целиком: Cmd-A, затем обычная вставка.
    ///
    /// Нужно ровно одному случаю — повторной чистке, когда в поле лежит наш же текст
    /// и ничего больше. Проверку «лежит ли» делает вызывающий (см. `EditWatcher.fieldText`)
    /// НЕПОСРЕДСТВЕННО перед вызовом: Cmd-A в чужом поле выделит чужое, и вставка его
    /// затрёт. Поэтому метод и не публичный соблазн на каждый день.
    @discardableResult
    public static func replace(_ text: String) -> InsertOutcome {
        guard !IsSecureEventInputEnabled() else { return .clipboardOnly(reason: "secure input") }
        guard hasAccessibility else { return .clipboardOnly(reason: "no accessibility") }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let selectDown = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: true),
              let selectUp = CGEvent(keyboardEventSource: source, virtualKey: keyA, keyDown: false)
        else {
            return .clipboardOnly(reason: "cgevent unavailable")
        }
        selectDown.flags = .maskCommand
        selectUp.flags = .maskCommand
        selectDown.post(tap: .cghidEventTap)
        selectUp.post(tap: .cghidEventTap)
        // Выделению нужно успеть примениться до того, как приедет вставка: иначе Cmd-V
        // ляжет рядом с текстом, а не вместо него.
        Thread.sleep(forTimeInterval: pasteboardSettleDelay)
        return insert(text)
    }

    /// Пауза между записью в пастборд и синтетическим Cmd-V: приложение-приёмник должно
    /// успеть увидеть новое содержимое. 20 мс с запасом хватает нативным приложениям
    /// (это больше одного тика системного нотификатора пастборда). Мосты буфера обмена
    /// виртуальных машин (Parallels, VMware, UTM) ходят заметно медленнее — если вставка
    /// в гостевую систему начнёт промахиваться, поднимать здесь до 40 мс.
    private static let pasteboardSettleDelay: TimeInterval = 0.02

    /// Виртуальный код клавиши V (0x09).
    private static let keyV = CGKeyCode(kVK_ANSI_V)
    /// Виртуальный код клавиши A (0x00) — «выделить всё» перед заменой.
    private static let keyA = CGKeyCode(kVK_ANSI_A)
}

/// Всё, чем конвейер трогает систему на последнем шаге: буфер обмена, вставка и проверка
/// поля ввода. Живая реализация ходит в AppKit и AX; тесты подставляют свою — прогон
/// не имеет права ни затирать буфер обмена пользователя, ни слать Cmd-V в чужое окно.
public struct TextDelivery: Sendable {
    public var focus: @Sendable () -> FocusVerdict
    public var insert: @Sendable (String) -> InsertOutcome
    public var copy: @Sendable (String) -> Void
    /// Заменить содержимое поля целиком. Отдельно от `insert`, потому что и зовётся
    /// отдельно — только повторной чисткой, и только когда в поле наш же текст.
    public var replace: @Sendable (String) -> InsertOutcome
    /// Что сейчас лежит в поле ввода; nil — поля нет или его не прочитать.
    ///
    /// Умолчаний у `replace` и `fieldText` намеренно нет. Живая замена шлёт Cmd-A и Cmd-V
    /// в чужое окно, и молчаливый дефолт превратил бы любой забывчивый тест в стрельбу
    /// по документу пользователя — ровно то, ради чего этот тип и существует.
    public var fieldText: @Sendable () -> String?

    public init(
        focus: @escaping @Sendable () -> FocusVerdict,
        insert: @escaping @Sendable (String) -> InsertOutcome,
        copy: @escaping @Sendable (String) -> Void,
        replace: @escaping @Sendable (String) -> InsertOutcome,
        fieldText: @escaping @Sendable () -> String?
    ) {
        self.focus = focus
        self.insert = insert
        self.copy = copy
        self.replace = replace
        self.fieldText = fieldText
    }

    public static let system = TextDelivery(
        focus: { FocusedFieldDetector.current() },
        insert: { TextInserter.insert($0) },
        copy: { TextInserter.copy($0) },
        replace: { TextInserter.replace($0) },
        fieldText: { EditWatcher.fieldText() }
    )
}
