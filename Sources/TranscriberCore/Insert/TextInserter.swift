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

    @discardableResult
    public static func insert(_ text: String) -> InsertOutcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
