import AppKit
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

    /// Как часто заглядывать в поле и сколько всего смотреть.
    ///
    /// Раньше снимок был ОДИН и поздний — через двадцать секунд. Из этого росла главная
    /// беда приёма: всё, что человек напечатал за эти двадцать секунд, попадало в «правку»,
    /// потому что отличить исправление нашего текста от начала собственной работы поздний
    /// снимок не может. Ровно так родилась единственная запись, которую механизм за всё
    /// время сделал: «добавлять → gjrть» («пок» в английской раскладке), то есть поле
    /// сняли посреди печати. Повториться такая пара не может никогда, а в словарь пара
    /// едет только со второго раза — приём работал вхолостую.
    ///
    /// Теперь заглядываем часто и рано: правят сразу, а работать поверх начинают потом.
    public static let defaultPollInterval: TimeInterval = 2
    public static let defaultPollWindow: TimeInterval = 15

    private let access: FieldAccess
    /// Такт и окно наблюдения. Не константы, а свойства — ради прогона: ждать штатные
    /// секунды в тестах незачем, а сам цикл проверять надо.
    private let pollInterval: TimeInterval
    private let pollWindow: TimeInterval
    private let queue = DispatchQueue(label: "online.nazarovych.cribe.edits")
    private static let logger = Logger(subsystem: "online.nazarovych.cribe", category: "Edits")

    /// Элемент, слепок и то, что мы туда вставили. Всё трогается только на `queue`.
    private var element: AnyObject?
    private var baseline: String?
    private var inserted: String?
    /// Однословные замены, замеченные за окно наблюдения, в порядке появления.
    private var seen: [ObservedCorrection] = []
    /// Состояние поля на прошлом такте: с ним сравниваем, чтобы знать, что случилось
    /// именно за эти две секунды.
    private var previous: String?
    /// Что менялось в поле и на каких секундах.
    private var changes: [FieldChange] = []

    public init(
        access: FieldAccess = .system,
        pollInterval: TimeInterval = EditWatcher.defaultPollInterval,
        pollWindow: TimeInterval = EditWatcher.defaultPollWindow
    ) {
        self.access = access
        self.pollInterval = pollInterval
        self.pollWindow = pollWindow
    }

    /// Взять поле под наблюдение сразу после удачной вставки.
    ///
    /// Предыдущее наблюдение при этом закрывается: если человек надиктовал второй раз,
    /// первый текст он уже либо поправил, либо нет, и ждать дольше нечего.
    public func watch(
        inserted text: String,
        then handle: @escaping @Sendable (FieldObservation) -> Void
    ) {
        collect(handle)
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { [self] in
            // Каждый отказ называется вслух и на уровне `.notice` — то есть ложится на диск.
            // Приём молчал во всех пяти местах разом, и по этой тишине нельзя было отличить
            // «поле не отдаёт текст» от «человек ничего не правил». Первый разбор жалобы
            // на неработающее автодобавление упёрся ровно в это.
            guard let field = access.focused() else {
                Self.logger.notice("Правки: фокуса нет — наблюдение не начато")
                return
            }
            guard let value = access.text(field) else {
                Self.logger.notice(
                    "Правки: поле не отдаёт содержимое (\(Self.frontmostApp(), privacy: .public)) — наблюдение не начато"
                )
                return
            }
            guard let point = Self.baseline(value: value, inserted: text) else {
                // Вставленного текста в поле нет: либо оно не отдаёт содержимое, либо текст
                // уехал не туда. Наблюдать не за чем.
                Self.logger.notice(
                    "Правки: вставленного текста в поле не видно (\(Self.frontmostApp(), privacy: .public)) — наблюдение не начато"
                )
                return
            }
            Self.logger.notice(
                "Правки: наблюдаю поле в \(Self.frontmostApp(), privacy: .public)"
            )
            element = field
            baseline = point
            previous = point
            inserted = text
            poll(elapsed: 0, handle: handle)
        }
    }

    /// Заглядывает в поле раз в `pollInterval` всё окно наблюдения и копит происходящее.
    ///
    /// Раньше здесь стоял один поздний снимок, и приложение само решало, какое изменение
    /// считать правкой. Решать это ему нечем: отличить исправление нашего текста от начала
    /// собственной работы человека можно только по смыслу. Поэтому копим ВСЁ, что случилось
    /// за пятнадцать секунд, вместе со временем, — и отдаём одной картиной тому, кто умеет
    /// судить (см. `DictionaryJudge`).
    ///
    /// Копится двумя мерками сразу. Однословные замены считаются от точки отсчёта: правка,
    /// сделанная на четвёртой секунде, обязана дожить до конца окна, даже если человек
    /// печатал рядом. Изменения такта считаются от прошлого снимка: только так видно,
    /// что произошло именно в эти две секунды, — а это и есть довод о времени.
    private func poll(elapsed: TimeInterval, handle: @escaping @Sendable (FieldObservation) -> Void) {
        queue.asyncAfter(deadline: .now() + pollInterval) { [self] in
            // Наблюдение закрыли (следующая диктовка) — этот такт уже ничей.
            guard let field = element, let before = baseline, let text = inserted else { return }
            let moment = elapsed + pollInterval

            guard let now = access.text(field) else {
                Self.logger.notice("Правки: поле перестало отдавать содержимое — отдаём найденное")
                finish(handle)
                return
            }
            if now != before {
                for correction in EditDiff.corrections(before: before, after: now, inserted: text)
                where !seen.contains(where: { $0.correction == correction }) {
                    seen.append(ObservedCorrection(correction: correction, after: moment))
                }
            }
            if let last = previous, now != last {
                let blocks = EditDiff.changes(before: last, after: now)
                if !blocks.isEmpty { changes.append(FieldChange(after: moment, blocks: blocks)) }
                previous = now
            }
            guard moment + pollInterval <= pollWindow else {
                finish(handle)
                return
            }
            poll(elapsed: moment, handle: handle)
        }
    }

    /// Окно закрылось: отдаём всю картину и снимаем наблюдение. Только на `queue`.
    private func finish(_ handle: @escaping @Sendable (FieldObservation) -> Void) {
        guard let point = baseline, let text = inserted else { return }
        let observation = FieldObservation(
            dictated: text,
            baseline: point,
            final: previous ?? point,
            changes: changes,
            corrections: seen
        )
        clear()
        // Поле не тронули вовсе — рассказывать не о чем и спрашивать не о чем.
        guard !observation.changes.isEmpty else {
            Self.logger.notice(
                "Правки: за \(self.pollWindow, format: .fixed(precision: 0)) с поле не менялось"
            )
            return
        }
        Self.logger.notice(
            """
            Правки: за окно наблюдения \(observation.changes.count, privacy: .public) изменений, \
            однословных замен \(observation.corrections.count, privacy: .public)
            """
        )
        handle(observation)
    }

    /// Снять наблюдение, ничего не отдавая. Только на `queue`.
    private func clear() {
        element = nil
        baseline = nil
        previous = nil
        inserted = nil
        seen = []
        changes = []
    }

    /// Закрыть идущее наблюдение досрочно и отдать всё, что нашлось.
    ///
    /// Зовётся, когда человек надиктовал снова: прошлый текст он к этому времени либо
    /// поправил, либо нет, и ждать дольше нечего.
    public func collect(_ handle: @escaping @Sendable (FieldObservation) -> Void) {
        queue.async { [self] in
            guard element != nil else { return }
            finish(handle)
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

    /// Кто был впереди в момент отказа. Без этого полевой отчёт «не доучивается» разобрать
    /// нечем: приём зависит от приложения-приёмника, а не от нас.
    static func frontmostApp() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "—"
    }

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
