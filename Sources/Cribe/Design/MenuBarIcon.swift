import AppKit
import SwiftUI

/// Значок в строке состояния: краб в покое и краб с точкой во время записи.
///
/// Шаблонный (`isTemplate`), то есть одноцветный: цвет в строке состояния нам не
/// принадлежит — система красит значок сама под тему, под подсветку открытого меню и под
/// «увеличенный контраст». Поэтому состояние записи различается **формой** (добавленной
/// точкой), а не красным цветом, как хотелось бы.
///
/// Рисунок — упрощённый силуэт, а не иконка приложения: в 18 pt полосы клешней, шесть ног
/// и глаза на стебельках сливаются в пятно (проверено листом размеров). Здесь остались
/// только купол и поднятые полосы-клешни, по которым краб и опознаётся.
struct MenuBarIcon: View {
    let recording: Bool

    /// Высота значка в строке состояния. Системные соседи (Wi-Fi, батарея) держат примерно
    /// столько же — крупнее наш краб выглядел бы чужеродной кляксой.
    private static let height: CGFloat = 17

    var body: some View {
        if let image = Self.glyph(recording: recording) {
            Image(nsImage: image)
        } else {
            // Ресурса нет (чужая сборка, запуск из тестов) — молча возвращаемся к системному
            // значку волны: пустое место в строке состояния хуже, чем не тот рисунок.
            Image(systemName: recording ? "waveform.badge.mic" : "waveform")
        }
    }

    private static func glyph(recording: Bool) -> NSImage? {
        guard let image = NSImage(named: recording ? "CrabGlyphRecording" : "CrabGlyph") else {
            return nil
        }
        let ratio = image.size.width / max(image.size.height, 1)
        image.size = NSSize(width: height * ratio, height: height)
        image.isTemplate = true
        return image
    }
}
