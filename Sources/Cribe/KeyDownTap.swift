import Carbon
import CoreGraphics
import Foundation
import CribeCore

/// Слушает одну-единственную клавишу (Esc) через CGEventTap и зовёт `onTap` на её нажатие.
/// Нужен отмене диктовки: она обязана срабатывать из любого приложения, а не только из своего.
///
/// Тап только слушающий (`.listenOnly`) — событие не съедается: Esc продолжает доходить
/// до фронтмост-приложения и делает там ровно то, что делал (закрывает попап, снимает
/// выделение). Нужен Accessibility — тот же, что и для вставки текста.
@MainActor
final class KeyDownTap {
    /// Escape. Константа из Carbon, а не число из головы.
    static let escapeKeyCode = Int64(kVK_Escape)

    /// Только нажатия клавиш: мышь и модификаторы отмене не нужны, а чем уже маска,
    /// тем меньше чужого потока событий проходит через процесс.
    private static let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue

    private let keyCode: Int64
    private let onTap: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(keyCode: Int64, onTap: @escaping () -> Void) {
        self.keyCode = keyCode
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
                    let listener = Unmanaged<KeyDownTap>.fromOpaque(userInfo).takeUnretainedValue()
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
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        // Систему устраивает только живой тап: после отключения его надо включить обратно,
        // иначе клавиша молча перестаёт работать до перезапуска приложения.
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .keyDown:
            // Из события читается ровно один код клавиши — ни символов, ни модификаторов,
            // ни набранного текста. Всё чужое уходит дальше нетронутым и незамеченным.
            guard event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }
            // Отмена уезжает из колбэка: работа внутри него — это задержка обработки события
            // и `kCGEventTapDisabledByTimeout`.
            Task { @MainActor [onTap] in onTap() }
        default:
            break
        }
    }
}
