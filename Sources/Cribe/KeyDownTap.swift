import Carbon
import CoreGraphics
import Foundation
import CribeCore

/// Перехватывает одну-единственную клавишу (Esc) через CGEventTap и зовёт `onTap` на её
/// нажатие. Нужен отмене диктовки: она обязана срабатывать из любого приложения, а не
/// только из своего.
///
/// Тап ЗАБИРАЕТ клавишу себе, а не только подслушивает. Раньше он был только слушающим:
/// Esc и отменял диктовку, и доходил до фронтмост-приложения — замысел был, чтобы он
/// продолжал закрывать там попапы. На деле это било по самому частому случаю: человек
/// диктует в Claude Code, передумывает, жмёт Esc — и вместе с диктовкой останавливает
/// работу Claude Code. Отмена диктовки не имеет права делать что-то ещё.
///
/// Забирает только пока тап стоит, а стоит он только на живой записи (см. `AppCore`):
/// вне записи Esc идёт в приложения как обычно, тапа в это время нет вовсе. Решение
/// «съесть или пропустить» — в `EscapeGate`, там же оно и проверено тестами. Нужен
/// Accessibility — тот же, что и для вставки текста.
@MainActor
final class KeyDownTap {
    /// Escape. Константа из Carbon, а не число из головы.
    static let escapeKeyCode = Int64(kVK_Escape)

    /// Нажатия и отпускания: отпускание тоже надо забрать, иначе оно уйдёт в приложение
    /// без своего нажатия. Мышь и модификаторы отмене не нужны.
    private static let eventMask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)

    /// Сколько ждать отпускания Esc, прежде чем снять тап без него: отпускание может и
    /// не прийти (тап отключила система), а висеть тапу незачем.
    private static let releaseGrace: TimeInterval = 1

    private let keyCode: Int64
    private let onTap: () -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gate = EscapeGate()

    init(keyCode: Int64, onTap: @escaping () -> Void) {
        self.keyCode = keyCode
        self.onTap = onTap
    }

    /// `false` — тап не поднялся (обычно нет разрешения Accessibility). Повторный вызов на
    /// работающем тапе ничего не делает — в том числе отменяет отложенное снятие.
    @discardableResult
    func start() -> Bool {
        gate.stopRequested = false
        guard tap == nil else { return true }
        guard TextInserter.hasAccessibility else { return false }

        // `self` уходит в колбэк неудержанным: владелец (AppCore) держит объект до выхода
        // из приложения, а `stop()` снимает тап раньше, чем объект мог бы исчезнуть.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Активный тап, а не `.listenOnly`: только он может не пропустить событие дальше.
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // Источник висит на главном run loop — колбэк приходит на главный поток.
                let listener = Unmanaged<KeyDownTap>.fromOpaque(userInfo).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated { listener.handle(type: type, event: event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
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

    /// Идемпотентна: снимает тап, если он стоял. Если Esc ещё зажат — снимает, когда его
    /// отпустят: запись гасится нажатием, и без отсрочки отпускание ушло бы в приложение.
    func stop() {
        guard tap != nil else { return }
        if gate.pressInFlight {
            gate.stopRequested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseGrace) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.gate.stopRequested else { return }
                    self.remove()
                }
            }
            return
        }
        remove()
    }

    private func remove() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        gate = EscapeGate()
    }

    /// `true` — событие съедено и дальше не идёт.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        // Систему устраивает только живой тап: после отключения его надо включить обратно,
        // иначе клавиша молча перестаёт работать до перезапуска приложения.
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        case .keyDown, .keyUp:
            // Из события читается ровно код клавиши и флаг автоповтора — ни символов,
            // ни модификаторов, ни набранного текста. Всё чужое уходит дальше нетронутым.
            let verdict = gate.decide(
                isDown: type == .keyDown,
                isEscape: event.getIntegerValueField(.keyboardEventKeycode) == keyCode,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
            if verdict.cancel {
                // Отмена уезжает из колбэка: работа внутри него — это задержка обработки
                // события и `kCGEventTapDisabledByTimeout`.
                Task { @MainActor [onTap] in onTap() }
            }
            if verdict.removeTap {
                // Не изнутри колбэка: снятый посреди обработки тап система вправе не
                // послушать, и отпускание, которое мы съедаем, всё-таки ушло бы дальше.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        // Новая запись успела поднять тап заново — тогда снимать нечего:
                        // `start()` сбрасывает просьбу о снятии.
                        guard let self, self.gate.stopRequested else { return }
                        self.remove()
                    }
                }
            }
            return verdict.swallow
        default:
            return false
        }
    }
}

/// Съесть ли событие клавиатуры и отменить ли диктовку — без CGEventTap, чтобы это можно
/// было проверить тестами.
///
/// Esc забирается целиком: нажатие, автоповтор при удержании и отпускание. Отменяет
/// диктовку только настоящее нажатие — автоповтор ту же отмену не повторяет. Всё, что
/// не Esc, проходит нетронутым.
struct EscapeGate {
    /// Esc нажат и ещё не отпущен.
    var pressInFlight = false
    /// Тап просили снять, пока Esc был зажат: снимаем на отпускании.
    var stopRequested = false

    struct Verdict: Equatable {
        var swallow: Bool
        var cancel: Bool
        var removeTap: Bool
    }

    mutating func decide(isDown: Bool, isEscape: Bool, isRepeat: Bool) -> Verdict {
        guard isEscape else { return Verdict(swallow: false, cancel: false, removeTap: false) }
        if isDown {
            // Повтор при удержании — то же нажатие: съедаем, но отменять второй раз нечего.
            if isRepeat, pressInFlight { return Verdict(swallow: true, cancel: false, removeTap: false) }
            pressInFlight = true
            return Verdict(swallow: true, cancel: true, removeTap: false)
        }
        // Отпускание без своего нажатия — не наше: Esc зажали ещё до того, как встал тап.
        guard pressInFlight else { return Verdict(swallow: false, cancel: false, removeTap: false) }
        pressInFlight = false
        return Verdict(swallow: true, cancel: false, removeTap: stopRequested)
    }
}
