import Foundation

/// Распознаёт «тап» по модификатору: нажали и отпустили, а между этим — ничего.
/// Чистая логика без CoreGraphics: события подаёт `ModifierKeyTap`.
///
/// Отменяют тап любое нажатие клавиши (⌘C правым ⌘ не должен запускать диктовку),
/// смена любого другого модификатора и удержание дольше `holdLimit`.
public struct ModifierTapDetector {
    /// Правый ⌘: keyCode 54, device-бит `NX_DEVICERCMDKEYMASK` во флагах события.
    public static let rightCommandKeyCode: Int64 = 54
    public static let rightCommandFlag: UInt64 = 0x10
    /// Дольше — это долгий аккорд с ⌘, а не намеренный тап.
    public static let holdLimit: TimeInterval = 0.6

    private let keyCode: Int64
    private let deviceFlag: UInt64
    /// Момент нажатия отслеживаемого модификатора; nil — тапа в ожидании нет.
    private var pressedAt: TimeInterval?

    public init(
        keyCode: Int64 = ModifierTapDetector.rightCommandKeyCode,
        deviceFlag: UInt64 = ModifierTapDetector.rightCommandFlag
    ) {
        self.keyCode = keyCode
        self.deviceFlag = deviceFlag
    }

    /// Событие смены модификаторов. `true` — это отпускание завершило тап.
    /// `flags` — сырые флаги события: device-бит отличает правый модификатор от левого,
    /// поэтому удержанный левый ⌘ не выдаёт себя за нажатый правый.
    public mutating func flagsChanged(keyCode: Int64, flags: UInt64, at time: TimeInterval) -> Bool {
        guard keyCode == self.keyCode else {
            pressedAt = nil  // любой другой модификатор — это аккорд, а не тап
            return false
        }
        guard flags & deviceFlag == 0 else {
            pressedAt = time
            return false
        }
        let pressed = pressedAt
        pressedAt = nil
        guard let pressed else { return false }
        return time - pressed <= Self.holdLimit
    }

    /// Любое нажатие клавиши во время удержания отменяет тап.
    public mutating func keyDown() {
        pressedAt = nil
    }

    /// Сброс после перерыва в потоке событий: пропущенные события делают ожидание недостоверным.
    public mutating func reset() {
        pressedAt = nil
    }
}
