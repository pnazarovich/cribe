import AppKit
import SwiftUI
import XCTest
@testable import Cribe
@testable import CribeCore

/// Ширина капсулы на записи. Числами, а не глазом: на живой диктовке бегущая строка вылезла
/// далеко за края капсулы и поехала прямо по обоям — на скриншоте видно, а в логах ни строки.
@MainActor
final class PillWidthTests: XCTestCase {

    /// Рендерит капсулу так же, как это делает панель, и отдаёт её настоящий размер.
    private func size(of pill: PanelPill) -> CGSize {
        let renderer = ImageRenderer(
            content: pill
                // Панель предлагает капсуле всё окно — именно в этом и была подозреваемая
                // беда: жадная строка забирала ширину окна, а не капсулы.
                .frame(width: 380, height: 120)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage else { return .zero }
        return image.size
    }

    /// Капсула с длинной бегущей строкой обязана остаться ровно `wordsWidth`, а не тянуться
    /// за текстом. Проверяем через непрозрачные пиксели: рамка рендера всегда 380 — врать
    /// будет именно она, а не то, что нарисовано.
    func testPillWithTickerStaysAtItsWidth() throws {
        let long = "зайди по SSH на VPS проверь webhooks и nginx потом задеплой на Vercel и посмотри логи"
        let pill = PanelPill(
            state: .recording(live: long, level: 0.3),
            language: .ru,
            translateToEnglish: false,
            style: .words
        )
        let short = PanelPill(
            state: .recording(live: "проверь webhooks и nginx", level: 0.3),
            language: .ru,
            translateToEnglish: false,
            style: .words
        )

        // Главный инвариант: ширина не зависит от длины текста. Точное число тут проверять
        // нечем — капсула законно рисует тень за своими краями, — а вот «выросла под текст»
        // видно сразу. Именно так оно и было сломано: лента тянула капсулу до края окна.
        XCTAssertEqual(try Self.drawn(pill), try Self.drawn(short), accuracy: 1)
        XCTAssertLessThan(try Self.drawn(pill), 380, "капсула не имеет права занять всё окно")
    }

    private static func drawn(_ pill: PanelPill) throws -> CGFloat {
        let renderer = ImageRenderer(content: pill.frame(width: 380, height: 120))
        renderer.scale = 1
        return try drawnWidth(of: XCTUnwrap(renderer.nsImage))
    }

    /// Волна — капсула прежней узкой ширины: расширяется она только под строку.
    func testPillWithWaveStaysNarrow() throws {
        let pill = PanelPill(
            state: .recording(live: "", level: 0.3),
            language: .ru,
            translateToEnglish: false,
            style: .wave
        )
        XCTAssertLessThan(try Self.drawn(pill), PanelPill.wordsWidth, "без строки капсула шириться не должна")
    }

    /// Ширина того, что реально нарисовано: крайние столбцы с непрозрачными пикселями.
    private static func drawnWidth(of image: NSImage) throws -> CGFloat {
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        var left = cg.width
        var right = -1
        for x in 0..<cg.width {
            for y in 0..<cg.height where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                left = min(left, x)
                right = max(right, x)
                break
            }
        }
        guard right >= left else { return 0 }
        return CGFloat(right - left + 1)
    }

    /// Кладёт кадр на диск, чтобы посмотреть глазами, когда числа спорят с ожиданием.
    func testDumpPillFrame() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CRIBE_DUMP_PILL"] == nil)
        let long = "зайди по SSH на VPS проверь webhooks и nginx потом задеплой на Vercel и посмотри логи"
        for (name, pill) in [
            ("pill-words", PanelPill(state: .recording(live: long, level: 0.3), language: .ru,
                                     translateToEnglish: false, style: .words)),
            ("pill-wave", PanelPill(state: .recording(live: "", level: 0.3), language: .ru,
                                    translateToEnglish: false, style: .wave)),
        ] {
            let renderer = ImageRenderer(content: pill.frame(width: 380, height: 120).background(.black))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            var rect = CGRect(origin: .zero, size: image.size)
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
    }

    /// Строка в отдельности: слот 200 pt, текст заведомо длиннее. Если нарисованное шире
    /// слота — обрезка не работает, и капсула тут ни при чём.
    func testTickerAloneStaysInsideItsSlot() throws {
        let long = "зайди по SSH на VPS проверь webhooks и nginx потом задеплой на Vercel и посмотри логи"
        let renderer = ImageRenderer(
            content: LiveTicker(text: long, reduceMotion: true)
                .frame(width: 200)
                .frame(width: 400, height: 60)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        if ProcessInfo.processInfo.environment["CRIBE_DUMP_PILL"] != nil {
            var rect = CGRect(origin: .zero, size: image.size)
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/ticker-alone.png"))
        }
        XCTAssertLessThanOrEqual(try Self.drawnWidth(of: image), 206, "лента вылезла за слот")
    }

    /// Где на самом деле стоят полосы растворения. Считаем непрозрачность по столбцам:
    /// у левого края она обязана быть заметно ниже, чем в середине, — это и есть дымка.
    /// Если профиль ровный, значит маски считаются не по окну, и их края ушли за рамку.
    func testHazeBandsSitAtTheWindowEdges() throws {
        let long = String(repeating: "проверь webhooks и nginx потом ", count: 4)
        let slot: CGFloat = 200
        let renderer = ImageRenderer(
            content: LiveTicker(text: long, reduceMotion: true)
                .frame(width: slot)
                .frame(width: slot, height: 40)
                .background(.black)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)

        func ink(from: Int, to: Int) -> CGFloat {
            var total: CGFloat = 0
            for x in from..<to {
                for y in 0..<cg.height {
                    total += bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0
                }
            }
            return total / CGFloat(to - from)
        }

        let edge = ink(from: 0, to: 14)
        let middle = ink(from: 90, to: 110)
        XCTAssertGreaterThan(middle, 0, "в середине окна обязан быть текст")
        XCTAssertLessThan(edge, middle * 0.6, "у левого края текст обязан растворяться")
    }

    /// А правый край, наоборот, обязан остаться резким: там стоит самое свежее слово —
    /// то единственное, ради чего строка вообще заведена. Широкая полоса растворения справа
    /// читалась ровно как «не вижу последних слов».
    func testNewestWordStaysCrisp() throws {
        let long = String(repeating: "проверь webhooks и nginx потом ", count: 4)
        let slot: CGFloat = 200
        let renderer = ImageRenderer(
            content: LiveTicker(text: long, reduceMotion: true)
                .frame(width: slot)
                .frame(width: slot, height: 40)
                .background(.black)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)

        func ink(from: Int, to: Int) -> CGFloat {
            var total: CGFloat = 0
            for x in from..<to {
                for y in 0..<cg.height {
                    total += bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0
                }
            }
            return total / CGFloat(to - from)
        }

        XCTAssertGreaterThan(ink(from: cg.width - 30, to: cg.width - 6), ink(from: 0, to: 24))
    }

    /// Короткая строка НЕ попадает в полосу растворения слева.
    ///
    /// Это регресс, который я сам и внёс, переведя ленту на выравнивание по левому краю:
    /// строка короче окна вставала в x = 0, то есть прямо в дымку, и её начало показывалось
    /// полупрозрачным и размытым — при том что слева от неё ничего не уезжало. А короткая
    /// строка — это ровно момент появления ленты, то есть первое, что видит человек.
    func testShortLineStartsClearOfTheHaze() throws {
        let slot: CGFloat = 203
        let renderer = ImageRenderer(
            content: LiveTicker(text: "раз два три", reduceMotion: true)
                .frame(width: slot)
                .frame(width: slot, height: 40)
                .background(.black)
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)

        var leftmost = cg.width
        for x in 0..<cg.width {
            for y in 0..<cg.height where (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.25 {
                leftmost = min(leftmost, x)
                break
            }
        }
        XCTAssertLessThan(leftmost, cg.width, "текст вообще нарисован")
        XCTAssertGreaterThan(CGFloat(leftmost), 56, "короткая строка начинается ПРАВЕЕ полосы растворения")
    }

    /// Кладёт саму ленту на диск, когда числа спорят с ожиданием.
    func testDumpTicker() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CRIBE_DUMP_PILL"] == nil)
        let long = "зайди по SSH на VPS проверь webhooks и nginx потом задеплой на Vercel"
        let renderer = ImageRenderer(
            content: LiveTicker(text: long, reduceMotion: true)
                .frame(width: 200)
                .frame(width: 260, height: 44)
                .background(.black)
        )
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.nsImage)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/ticker.png"))
    }
}
