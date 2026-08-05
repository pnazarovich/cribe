import CoreGraphics
import Foundation
import TranscriberCore

/// Слушает «голый» модификатор (по умолчанию правый ⌘) через CGEventTap и зовёт `onTap`,
/// когда клавишу нажали и отпустили вхолостую. Решение о тапе принимает `ModifierTapDetector`.
///
/// Тап только слушающий (`.listenOnly`): чужие ⌘-аккорды проходят нетронутыми.
/// Нужен Accessibility — тот же, что и для вставки текста.
@MainActor
final class ModifierKeyTap {
    /// Клавиатура и мышь: всё, чем можно составить аккорд с ⌘ (⌘-клик, ⌘-скролл, ⌘-drag).
    /// Само событие нас не интересует — только факт, что оно было.
    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .scrollWheel,
        ]
        return types.reduce(into: CGEventMask(0)) { $0 |= CGEventMask(1) << $1.rawValue }
    }()

    /// Расхождение со `systemUptime`, после которого штамп события считаем недостоверным.
    private static let timestampTolerance: TimeInterval = 5

    private let onTap: () -> Void
    private var detector: ModifierTapDetector
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// `blockingFlags` — device-биты остальных хоткей-модификаторов: при удержанном соседе
    /// тап не начинается, иначе аккорд двух хоткеев запускал бы диктовку.
    init(
        keyCode: Int64 = ModifierTapDetector.rightCommandKeyCode,
        deviceFlag: UInt64 = ModifierTapDetector.rightCommandFlag,
        blockingFlags: UInt64 = 0,
        onTap: @escaping () -> Void
    ) {
        self.detector = ModifierTapDetector(
            keyCode: keyCode,
            deviceFlag: deviceFlag,
            blockingFlags: blockingFlags
        )
        self.onTap = onTap
    }

    /// `false` — тап не поднялся (обычно нет разрешения Accessibility). Повторный вызов на
    /// работающем тапе ничего не делает.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard TextInserter.hasAccessibility else { return false }

        // `self` уходит в колбэк неудержанным: владелец (AppCore) держит объект до выхода
        // из приложения, а `stop()` снимает тап раньше, чем объект мог бы исчезнуть.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, userInfo in
                // Источник висит на главном run loop — колбэк приходит на главный поток.
                if let userInfo {
                    let listener = Unmanaged<ModifierKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                    MainActor.assumeIsolated { listener.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        detector.reset()
        return true
    }

    /// Идемпотентна: снимает тап, если он стоял.
    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        detector.reset()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        // Систему устраивает только живой тап: после отключения его надо включить обратно,
        // иначе клавиша молча перестаёт работать до перезапуска приложения.
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            detector.reset()
        // Из событий клавиш и мыши не читается НИЧЕГО — ни keyCode, ни координаты, ни символы.
        // Нужен только факт: между нажатием и отпусканием ⌘ что-то произошло, значит это аккорд.
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel:
            detector.cancel()
        case .flagsChanged:
            let fired = detector.flagsChanged(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags.rawValue,
                at: Self.seconds(of: event)
            )
            // Диктовка стартует вне колбэка: холодный запуск AVAudioEngine внутри него —
            // это задержка обработки события и `kCGEventTapDisabledByTimeout`.
            if fired {
                Task { @MainActor [onTap] in onTap() }
            }
        default:
            break
        }
    }

    /// Аппаратное время события в секундах: оно не врёт, даже если run loop подвис
    /// и колбэк пришёл с опозданием.
    ///
    /// `CGEventTimestamp` в SDK описан как «наносекунды с момента старта системы» — та же
    /// точка отсчёта, что у `systemUptime` (это не mach-тики: на Apple Silicon перевод через
    /// timebase разошёлся бы в 41.7 раза и превратил любой тап в «долгое удержание»).
    /// Заметное расхождение со `systemUptime` означает событие без штампа — берём часы колбэка.
    private static func seconds(of event: CGEvent) -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        let stamp = TimeInterval(event.timestamp) / 1_000_000_000
        return abs(uptime - stamp) < timestampTolerance ? stamp : uptime
    }
}
