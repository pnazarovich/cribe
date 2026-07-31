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
    private let onTap: () -> Void
    private var detector: ModifierTapDetector
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(keyCode: Int64 = ModifierTapDetector.rightCommandKeyCode, onTap: @escaping () -> Void) {
        self.detector = ModifierTapDetector(keyCode: keyCode)
        self.onTap = onTap
    }

    /// `false` — тап не поднялся (обычно нет разрешения Accessibility). Повторный вызов на
    /// работающем тапе ничего не делает.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard TextInserter.hasAccessibility else { return false }

        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                // Источник висит на главном run loop — колбэк приходит на главный поток.
                if let userInfo {
                    let listener = Unmanaged<ModifierKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                    MainActor.assumeIsolated { listener.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

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
        case .keyDown:
            detector.keyDown()
        case .flagsChanged:
            let fired = detector.flagsChanged(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags.rawValue,
                at: ProcessInfo.processInfo.systemUptime
            )
            if fired { onTap() }
        default:
            break
        }
    }
}
