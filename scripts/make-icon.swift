import AppKit
import CoreText
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = Double(size) / 1024
    context.scaleBy(x: scale, y: scale)

    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864),
                 xRadius: 194, yRadius: 194).fill()

    let font = NSFont.systemFont(ofSize: 600, weight: .bold) as CTFont
    var character: UniChar = 116 // t
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
          let path = CTFontCreatePathForGlyph(font, glyph, nil) else {
        throw CocoaError(.coderInvalidValue)
    }
    let bounds = path.boundingBoxOfPath
    context.translateBy(x: 512 - bounds.midX, y: 512 - bounds.midY)
    context.setFillColor(NSColor.white.cgColor)
    context.addPath(path)
    context.fillPath()

    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try drawIcon(size: points * multiplier).write(to: directory.appendingPathComponent(name))
    }
}
