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

        // Даём приложению-приёмнику увидеть новое содержимое буфера. 20 мс — запас
        // над одним тиком системного пастборд-нотификатора; 50 мс были взяты с потолка
        // и стоили лишние 30 мс на каждой вставке.
        Thread.sleep(forTimeInterval: 0.02)

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

    /// Виртуальный код клавиши V (0x09).
    private static let keyV = CGKeyCode(kVK_ANSI_V)
}
