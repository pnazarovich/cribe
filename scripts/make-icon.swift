#!/usr/bin/env swift
// Готовит иконку приложения из исходного квадратного рисунка: вписывает его в скруглённый
// квадрат и оставляет вокруг прозрачные поля, которых система ждёт от маковской иконки.
// Сам рисунок не трогается — ни фон, ни цвета.
//
// Запуск: swift scripts/make-icon.swift <source.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <source.png> <out.png>\n".utf8))
    exit(1)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let source = NSImage(contentsOf: sourceURL),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("не читается исходник: \(sourceURL.path)\n".utf8))
    exit(1)
}

let canvas: CGFloat = 1024
// Поля и радиус — пропорции классической маковской иконки: рисунок занимает не весь квадрат,
// иначе в доке он выглядит крупнее соседей и упирается в их края. (В macOS 26 у слоёных
// иконок поля другие, почти нулевые, но там и формат другой — мы отдаём классический .icns.)
let margin: CGFloat = 100
let plate = CGRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
let corner = plate.width * (232.0 / 1024.0)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("не создать контекст\n".utf8))
    exit(1)
}
ctx.interpolationQuality = .high

// Скруглённый квадрат как маска: всё, что вне его, остаётся прозрачным.
ctx.addPath(CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil))
ctx.clip()

// Исходник квадратный — вписываем целиком, без обрезки по краям.
ctx.draw(sourceCG, in: plate)

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("не закодировать PNG\n".utf8))
    exit(1)
}
do {
    try png.write(to: outURL)
} catch {
    FileHandle.standardError.write(Data("не записать \(outURL.path): \(error)\n".utf8))
    exit(1)
}
print("OK: \(outURL.path)")
