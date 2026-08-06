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

    /// Пауза между записью в пастборд и синтетическим Cmd-V: приложение-приёмник должно
    /// успеть увидеть новое содержимое. 20 мс с запасом хватает нативным приложениям
    /// (это больше одного тика системного нотификатора пастборда). Мосты буфера обмена
    /// виртуальных машин (Parallels, VMware, UTM) ходят заметно медленнее — если вставка
    /// в гостевую систему начнёт промахиваться, поднимать здесь до 40 мс.
    private static let pasteboardSettleDelay: TimeInterval = 0.02

    /// Виртуальный код клавиши V (0x09).
    private static let keyV = CGKeyCode(kVK_ANSI_V)
}

/// Всё, чем конвейер трогает систему на последнем шаге: буфер обмена, вставка и проверка
/// поля ввода. Живая реализация ходит в AppKit и AX; тесты подставляют свою — прогон
/// не имеет права ни затирать буфер обмена пользователя, ни слать Cmd-V в чужое окно.
public struct TextDelivery: Sendable {
    public var focus: @Sendable () -> FocusVerdict
    public var insert: @Sendable (String) -> InsertOutcome
    public var copy: @Sendable (String) -> Void

    public init(
        focus: @escaping @Sendable () -> FocusVerdict,
        insert: @escaping @Sendable (String) -> InsertOutcome,
        copy: @escaping @Sendable (String) -> Void
    ) {
        self.focus = focus
        self.insert = insert
        self.copy = copy
    }

    public static let system = TextDelivery(
        focus: { FocusedFieldDetector.current() },
        insert: { TextInserter.insert($0) },
        copy: { TextInserter.copy($0) }
    )
}
