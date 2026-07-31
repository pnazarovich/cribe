#!/usr/bin/env swift
// Рисует иконку приложения (звуковая волна) в PNG 1024×1024.
// Запуск: swift scripts/make-icon.swift out.png
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.png>\n".utf8))
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])

let canvas: CGFloat = 1024
let margin: CGFloat = 100 // прозрачные поля вокруг скруглённого квадрата (правило macOS)
let plate = CGRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
let corner = plate.width * (232.0 / 1024.0) // squircle в стиле macOS

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("cannot create bitmap context\n".utf8))
    exit(1)
}

let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)

// Мягкая тень под плашкой.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44, color: rgb(20, 12, 60, 0.35))
ctx.setFillColor(rgb(58, 46, 140))
ctx.addPath(platePath)
ctx.fillPath()
ctx.restoreGState()

// Вертикальный градиент: фиолетовый сверху → тёмный индиго снизу.
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: sRGB,
    colors: [rgb(123, 92, 214), rgb(58, 46, 140)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY),
    options: []
)
ctx.restoreGState()

// Звуковая волна: 7 белых столбиков со скруглёнными торцами, симметрично от центра.
let heightFactors: [CGFloat] = [0.30, 0.55, 0.82, 1.0, 0.82, 0.55, 0.30]
let barWidth: CGFloat = 56
let barGap: CGFloat = 38
let maxBarHeight: CGFloat = 540
let totalWidth = CGFloat(heightFactors.count) * barWidth + CGFloat(heightFactors.count - 1) * barGap
var x = plate.midX - totalWidth / 2

ctx.setFillColor(rgb(255, 255, 255))
for factor in heightFactors {
    let h = maxBarHeight * factor
    let bar = CGRect(x: x, y: plate.midY - h / 2, width: barWidth, height: h)
    ctx.addPath(CGPath(
        roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil
    ))
    ctx.fillPath()
    x += barWidth + barGap
}

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("cannot encode PNG\n".utf8))
    exit(1)
}
do {
    try png.write(to: outURL)
} catch {
    FileHandle.standardError.write(Data("cannot write \(outURL.path): \(error)\n".utf8))
    exit(1)
}
print("OK: \(outURL.path)")
