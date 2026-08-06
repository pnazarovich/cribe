import Foundation

/// Распознаёт «тап» по модификатору: нажали и отпустили, а между этим — ничего.
/// Чистая логика без CoreGraphics: события подаёт `ModifierKeyTap`.
///
/// Отменяют тап любое действие пользователя между нажатием и отпусканием — клавиша (⌘C правым
/// ⌘ не должен запускать диктовку), клик или скролл мышью, — а также смена любого другого
/// модификатора и удержание дольше `holdLimit`. А если в момент нажатия удержан чужой
/// хоткей-модификатор (`blockingFlags`), ожидание тапа не заводится вовсе.
public struct ModifierTapDetector {
    /// Правый ⌘: keyCode 54, device-бит `NX_DEVICERCMDKEYMASK` во флагах события.
    public static let rightCommandKeyCode: Int64 = 54
    public static let rightCommandFlag: UInt64 = 0x10
    /// Правый ⌥: keyCode 61 (`kVK_RightOption`), device-бит `NX_DEVICERALTKEYMASK`.
    public static let rightOptionKeyCode: Int64 = 61
    public static let rightOptionFlag: UInt64 = 0x40
    /// Дольше — это долгий аккорд с ⌘, а не намеренный тап.
    public static let holdLimit: TimeInterval = 0.6

    private let keyCode: Int64
    private let deviceFlag: UInt64
    /// Device-биты чужих хоткей-модификаторов. Зажатая соседняя хоткей-клавиша не шлёт
    /// своего события, пока её держат, поэтому на нажатии нашей клавиши узнать о ней можно
    /// только по флагам: удержанный правый ⌘ плюс тап правым ⌥ — это аккорд двух хоткеев,
    /// и запускать по нему диктовку нельзя.
    private let blockingFlags: UInt64
    /// Момент нажатия отслеживаемого модификатора; nil — тапа в ожидании нет.
    private var pressedAt: TimeInterval?

    public init(
        keyCode: Int64 = ModifierTapDetector.rightCommandKeyCode,
        deviceFlag: UInt64 = ModifierTapDetector.rightCommandFlag,
        blockingFlags: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.deviceFlag = deviceFlag
        self.blockingFlags = blockingFlags
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
            // Нажатие: ждать тапа начинаем, только если чужой хоткей-модификатор не удержан.
            // Иначе это аккорд двух хоткеев — ожидание не заводим вовсе (а заодно снимаем
            // старое, если оно почему-то осталось).
            pressedAt = flags & blockingFlags == 0 ? time : nil
            return false
        }
        let pressed = pressedAt
        pressedAt = nil
        guard let pressed else { return false }
        return time - pressed <= Self.holdLimit
    }

    /// Любой ввод во время удержания (клавиша, клик, скролл) отменяет тап.
    public mutating func cancel() {
        pressedAt = nil
    }

    /// Сброс после перерыва в потоке событий: пропущенные события делают ожидание недостоверным.
    public mutating func reset() {
        pressedAt = nil
    }
}
