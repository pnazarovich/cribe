import AppKit
import SwiftUI

/// Краб — фирменный знак Cribe и единственная точка, откуда он берётся во всём интерфейсе:
/// строка состояния, шапка карточки, кнопки. Поставить его в новом месте — `CrabGlyph()`.
///
/// У SF Symbols краба нет, поэтому глиф свой: PDF в ресурсах приложения с `isTemplate = true`.
/// Шаблон значит, что цвет рисует не он: в строке состояния — система (тема, подсветка
/// открытого меню, «увеличенный контраст»), в окнах — `foregroundStyle`. Вектор, а не растр:
/// он рисуется под плотность экрана и под «крупный курсор меню».
///
/// Рисунок собирает `scripts/make-crab-glyph.swift` — там же сказано, чем он упрощён
/// против иконки приложения и почему.
struct CrabGlyph: View {
    /// Краб с точкой записи. Состояние различается **формой**, а не красным цветом:
    /// в строке состояния цвет нам не принадлежит.
    var recording = false
    /// Высота в точках. По умолчанию — под строку текста.
    var height: CGFloat = 14

    /// Высота значка в строке состояния. Системные соседи (Wi-Fi, батарея) держат примерно
    /// столько же — крупнее краб выглядел бы чужеродной кляксой.
    static let menuBarHeight: CGFloat = 17

    var body: some View {
        if let image = Self.image(recording: recording, height: height) {
            Image(nsImage: image).renderingMode(.template)
        } else {
            // Ресурса нет (чужая сборка, запуск из тестов) — молча возвращаемся к системному
            // значку волны: пустое место хуже, чем не тот рисунок.
            Image(systemName: recording ? "waveform.badge.mic" : "waveform")
        }
    }

    private static func image(recording: Bool, height: CGFloat) -> NSImage? {
        guard let source = NSImage(named: recording ? "CrabGlyphRecording" : "CrabGlyph"),
              // Копия, а не общий объект: один глиф живёт в строке состояния и в окнах
              // разного размера, и менять размер общему значило бы менять его всем сразу.
              let image = source.copy() as? NSImage else { return nil }
        let ratio = source.size.width / max(source.size.height, 1)
        image.size = NSSize(width: (height * ratio).rounded(), height: height)
        image.isTemplate = true
        return image
    }
}
