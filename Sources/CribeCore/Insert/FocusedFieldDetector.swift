import AppKit
import ApplicationServices
import Foundation

/// Есть ли прямо сейчас поле, в которое осмысленно вставлять текст.
public enum FocusState: Sendable, Equatable {
    case editable
    case notEditable
    /// Судить не о чем: разрешения нет, приложение не ответило или его AX-дерево
    /// принципиально не различает «поле» и «не поле» (веб-контент).
    case unknown
}

/// Вердикт вместе с ролью, которая к нему привела: роль нужна логу, иначе полевой отчёт
/// «карточка не появилась» разобрать нечем.
public struct FocusVerdict: Sendable, Equatable {
    public let state: FocusState
    public let role: String?

    public init(state: FocusState, role: String?) {
        self.state = state
        self.role = role
    }
}

/// Сырой ответ AX-слоя о сфокусированном элементе. Отдельный тип — это шов: раскладка
/// «что ответила система → вердикт» проверяется тестами, ни разу не трогая живой AX.
public enum FocusedElementProbe: Sendable, Equatable {
    /// AX недоступен: нет разрешения, API выключен, приложение не отвечает.
    case unavailable
    /// Фокуса нет вовсе — ни поля, ни любого другого элемента.
    case noFocus
    /// `valueSettable` — можно ли записать `AXValue`; `hasSelectedTextRange` — отдаёт ли
    /// элемент выделение текстом; `isWebContext` — торчат ли из элемента текстовые маркеры
    /// WebKit/Blink (`AXStartTextMarker` и родня), которых у нативных вью не бывает;
    /// `hasEditableAncestor` — торчит ли `AXEditableAncestor`, которым движок помечает узлы
    /// ВНУТРИ редактируемой области (поле, `contenteditable`).
    case element(
        role: String?,
        valueSettable: Bool,
        hasSelectedTextRange: Bool,
        isWebContext: Bool,
        hasEditableAncestor: Bool
    )
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

    /// Сколько ждём ответа от чужого приложения на один запрос…
    private static let messagingTimeout: Float = 0.25
    /// …и сколько на весь опрос целиком: запросов пять (фокус, роль, записываемость,
    /// выделение, список атрибутов), и зависшее приложение не должно задерживать вставку
    /// на секунду с лишним. Дедлайн проверяется перед КАЖДЫМ запросом, включая самый первый,
    /// поэтому потолок ожидания — дедлайн плюс таймаут одного последнего запроса, а не
    /// сумма всех пяти. Просрочка — это `.unavailable`, то есть обычный Cmd-V.
    private static let overallDeadline: TimeInterval = 0.5

    /// Вердикт по живой системе. Блокирующий вызов (ходит в чужой процесс) — звать с фона.
    public static func current() -> FocusVerdict {
        classify(systemProbe())
    }

    /// Попросить приложение впереди открыть дерево доступности. Звать в начале записи:
    /// к моменту, когда текст будет готов, дерево успеет построиться.
    ///
    /// Приложения на Electron и Chromium — Claude, ChatGPT, Codex, Slack, VS Code — строят
    /// дерево доступности только по просьбе. Без неё системный вопрос «где фокус» получает
    /// пустоту, детектор отвечал «поля нет», и текст уезжал в карточку. Журнал показал это
    /// дословно: `фокус=notEditable роль=— впереди=com.anthropic.claudefordesktop → карточка`,
    /// и так же у `com.openai.codex`. На машине автора то же приложение отвечало полем:
    /// дерево там давно включил кто-то ещё, поэтому беда и была видна только у других людей.
    ///
    /// Просьба — атрибут `AXManualAccessibility`: его заводит Electron ровно для этого, а
    /// нативные приложения отвечают «не поддерживаю» и ничего не меняют. Возвращает,
    /// принял ли его кто-то, — то есть Chromium ли впереди.
    @discardableResult
    public static func openAccessibilityOfFrontmostApp() -> Bool {
        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              !refusesAccessibilityRequest(front.bundleIdentifier)
        else { return false }
        let pid = front.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    /// Чистая функция: весь смысл детектора живёт здесь и целиком покрыт тестами.
    public static func classify(_ probe: FocusedElementProbe) -> FocusVerdict {
        switch probe {
        case .unavailable:
            return FocusVerdict(state: .unknown, role: nil)
        case .noFocus:
            return FocusVerdict(state: .notEditable, role: nil)
        case .element(let role, let valueSettable, let hasSelectedTextRange, let isWebContext,
                      let hasEditableAncestor):
            if let role, editableRoles.contains(role) {
                return FocusVerdict(state: .editable, role: role)
            }
            // Записываемое значение — признак настоящего поля: так ведут себя и нативные
            // поля, и Electron-композеры (замерено: Telegram, cmux, Claude — все settable).
            if valueSettable {
                return FocusVerdict(state: .editable, role: role)
            }
            // Узел внутри редактируемой области: сам он может быть хоть строкой текста, но
            // курсор стоит в композере (`contenteditable` Gmail, Slack, ChatGPT) — это поле.
            if hasEditableAncestor {
                return FocusVerdict(state: .editable, role: role)
            }
            // Веб-узел, у которого нет НИ ОДНОГО признака редактируемости, — не поле.
            //
            // Замерено на живом Chrome (полный экран, 2026-08-02), одна и та же проба:
            //   страница без полей   → AXWebArea,  settable=false, AXEditableAncestor нет;
            //   `<input autofocus>`  → AXTextField, settable=true,  AXEditableAncestor есть;
            //   `contenteditable`    → AXTextArea,  settable=true,  AXEditableAncestor есть;
            //   `<button autofocus>` → AXButton,    settable=false, AXEditableAncestor нет.
            // То есть браузер поле от страницы ОТЛИЧАЕТ, и прежнее «веб — это всегда не знаю»
            // было неверным: оно уводило в слепой Cmd-V каждую диктовку поверх страницы.
            // Признак «есть выделение текстом» тут по-прежнему не в счёт — его отдаёт даже
            // кнопка, ради чего веб и различается отдельно.
            if isWebContext {
                return FocusVerdict(state: .notEditable, role: role)
            }
            // Роли нет вовсе, но элемент отдаёт выделение текстом — нативное поле без роли.
            // Вне веба этот признак не врёт: текстовых маркеров у таких элементов не бывает.
            if role == nil, hasSelectedTextRange {
                return FocusVerdict(state: .editable, role: role)
            }
            return FocusVerdict(state: .notEditable, role: role)
        }
    }

    /// Редакторы семейства VS Code, которым просьбу о дереве НЕ шлём.
    ///
    /// На `AXManualAccessibility` Electron включает режим доступности на всё время жизни
    /// процесса, а VS Code с настройкой по умолчанию (`editor.accessibilitySupport: auto`)
    /// принимает это за экранного диктора и переводит редактор в режим для него: гаснет
    /// перенос строк, меняется поведение. Ради одной диктовки ломать человеку редактор
    /// нельзя. Поле в них находится и без просьбы, а если нет — это «не знаю», то есть
    /// вставка: в редакторе фокус почти всегда в тексте.
    static let editorsWithScreenReaderMode: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "com.vscodium",
    ]

    static func refusesAccessibilityRequest(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(editorsWithScreenReaderMode.contains) ?? false
    }

    /// Принял ли последнюю просьбу Chromium. Пишется и читается внутри одного опроса.
    private nonisolated(unsafe) static var chromiumAnswered = false

    /// Попросить приложение впереди открыть дерево и спросить его о фокусе напрямую.
    /// Дереву нужны десятки миллисекунд: одна короткая пауза, и ещё один вопрос.
    private static func focusAfterOpening(outOfTime: () -> Bool) -> CFTypeRef? {
        // Редактору VS Code просьбу не шлём, но и «поля нет» ему не верим — см. выше.
        if refusesAccessibilityRequest(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            chromiumAnswered = true
            return nil
        }
        chromiumAnswered = openAccessibilityOfFrontmostApp()
        guard chromiumAnswered,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.08) }
            if outOfTime() { return nil }
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused {
                return focused
            }
        }
        return nil
    }

    private static func systemProbe() -> FocusedElementProbe {
        // Разрешение то же, что у вставки: без него системный элемент отдаёт `.apiDisabled`,
        // но спрашивать систему ради заведомо неизвестного ответа незачем.
        guard AXIsProcessTrusted() else { return .unavailable }
        let started = Date()
        /// Общий бюджет вышел: дальше не спрашиваем, отвечаем «не знаю».
        func outOfTime() -> Bool { Date().timeIntervalSince(started) > overallDeadline }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        if outOfTime() { return .unavailable }
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        switch status {
        case .success:
            break
        // Фокуса нет — или приложение на Chromium ещё не открыло дерево доступности.
        // Различаем: просим открыть и спрашиваем само приложение ещё раз.
        case .noValue, .attributeUnsupported:
            switch focusAfterOpening(outOfTime: outOfTime) {
            case .some(let element): focused = element
            // Chromium просьбу принял, а фокуса всё равно не назвал — дерево не успело
            // построиться. Это «не знаю», а «не знаю» вставляется, а не уходит в карточку.
            case .none where chromiumAnswered: return .unavailable
            // Нативное приложение без фокуса: рабочий стол, окно без полей.
            case .none: return .noFocus
            }
        // Всё остальное (API выключен, приложение зависло, элемент протух) — не наше дело.
        default:
            return .unavailable
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unavailable }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement

        if outOfTime() { return .unavailable }
        var roleValue: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success
            ? roleValue as? String
            : nil

        if outOfTime() { return .unavailable }
        var settable: DarwinBoolean = false
        let valueSettable =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue

        if outOfTime() { return .unavailable }
        var range: CFTypeRef?
        let hasSelectedTextRange = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &range
        ) == .success

        // Текстовые маркеры — расширение WebKit/Blink: у нативных AppKit-вью их не бывает,
        // а любой узел веб-страницы их отдаёт. Это и есть метка «здесь веб-контент».
        // Тем же списком приходит `AXEditableAncestor` — метка «узел внутри редактируемого».
        if outOfTime() { return .unavailable }
        var names: CFArray?
        let attributes = AXUIElementCopyAttributeNames(element, &names) == .success
            ? ((names as? [String]) ?? [])
            : []

        return .element(
            role: role,
            valueSettable: valueSettable,
            hasSelectedTextRange: hasSelectedTextRange,
            isWebContext: attributes.contains("AXStartTextMarker"),
            hasEditableAncestor: attributes.contains("AXEditableAncestor")
        )
    }
}
