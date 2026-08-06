#!/usr/bin/env swift
// Рисует шаблонный глиф краба для строки состояния: тот же образ, что на иконке, но
// упрощённый до силуэта, который читается в 18 pt.
//
// Что оставлено и почему: **полосы вместо клешней** — это опознавательный признак, краб
// сделан из звука, и без полос он превращается в безымянного жучка. Что выброшено: глаза
// на стебельках (в 18 pt это две точки грязи над куполом) и половина ног (шесть тонких
// сливаются в бахрому). Осталось четыре толстые.
//
// Вывод — два PDF: обычный и с точкой записи. Вектор, а не растр: в строке состояния глиф
// рисуется под плотность экрана и под «крупный курсор меню».
//
// Запуск (вручную, когда меняется рисунок): swift scripts/make-crab-glyph.swift
import AppKit

let side: CGFloat = 100
let out = URL(fileURLWithPath: "Sources/Cribe/Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

/// Толщина всех штрихов. Крупная намеренно: в 18 pt это чуть больше полутора точек —
/// тоньше начинает исчезать, толще выглядит жирнее системных значков рядом.
let stroke: CGFloat = 11

func bar(x: CGFloat, bottom: CGFloat, height: CGFloat) -> NSBezierPath {
    NSBezierPath(
        roundedRect: NSRect(x: x - stroke / 2, y: bottom, width: stroke, height: height),
        xRadius: stroke / 2,
        yRadius: stroke / 2
    )
}

func leg(from: NSPoint, to: NSPoint) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = stroke
    path.lineCapStyle = .round
    path.move(to: from)
    path.line(to: to)
    return path
}

func draw(recording: Bool) -> Data {
    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    let data = NSMutableData()
    var box = bounds
    guard let consumer = CGDataConsumer(data: data),
          let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { exit(1) }

    ctx.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSColor.black.set()

    // Купол панциря: половина эллипса, посаженная на плоское днище.
    let shell = NSBezierPath()
    shell.appendArc(
        withCenter: NSPoint(x: side / 2, y: 40),
        radius: 30,
        startAngle: 0,
        endAngle: 180
    )
    shell.close()
    shell.fill()

    // Клешни: по две полосы разной высоты с каждой стороны — та самая волна с иконки.
    // Они **подняты над куполом**: на иконке клешни торчат вверх, и если поставить их
    // вровень с панцирем, силуэт читается как столбы по бокам, а не как краб.
    // Внешняя ниже внутренней — силуэт получается ступенчатым, а не забором.
    for (x, height) in [(9.0, 30.0), (25.0, 46.0)] {
        bar(x: CGFloat(x), bottom: 40, height: CGFloat(height)).fill()
        bar(x: side - CGFloat(x), bottom: 40, height: CGFloat(height)).fill()
    }

    // Ноги: четыре, толстые, от днища вниз-наружу.
    // Короткие: длинные лезли на полосы клешней и превращали низ в мешанину.
    for (dx, spread) in [(12.0, 6.0), (28.0, 10.0)] {
        leg(from: NSPoint(x: side / 2 - CGFloat(dx), y: 38),
            to: NSPoint(x: side / 2 - CGFloat(dx) - CGFloat(spread), y: 20)).stroke()
        leg(from: NSPoint(x: side / 2 + CGFloat(dx), y: 38),
            to: NSPoint(x: side / 2 + CGFloat(dx) + CGFloat(spread), y: 20)).stroke()
    }

    // Точка записи — отдельным глифом, а не цветом: в строке состояния цвет нам не принадлежит.
    if recording {
        NSBezierPath(ovalIn: NSRect(x: side - 20, y: 0, width: 20, height: 20)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
    ctx.closePDF()
    return data as Data
}

try draw(recording: false).write(to: out.appendingPathComponent("CrabGlyph.pdf"))
try draw(recording: true).write(to: out.appendingPathComponent("CrabGlyphRecording.pdf"))
print("OK: \(out.path)/CrabGlyph.pdf, CrabGlyphRecording.pdf")
