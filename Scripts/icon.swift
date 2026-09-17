import AppKit
import CoreText

// Center the visible glyph outline, not the font's baseline/line box.
let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 32, nil)
var character: UniChar = 0x8A00 // 言
var glyph: CGGlyph = 0
precondition(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { fatalError("Missing icon glyph") }
let bounds = outline.boundingBoxOfPath
let size: CGFloat = 16
let padding: CGFloat = 2.5
let scale = (size - 2 * padding) / max(bounds.width, bounds.height)
let badgeColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
let image = NSImage(size: NSSize(width: size, height: size))
// TISIconIsTemplate in Info.plist makes the system input menu tint this alpha mask.
// NSImage metadata alone is not preserved in TIFF files.
image.isTemplate = true

// Explicit point sizes avoid the previous 32-point canvas and baseline offset.
for density in [1, 2] {
    let pixels = Int(size) * density
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    // Solid badge with a genuinely transparent glyph, not white lettering.
    context.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: 15, height: 15),
        cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
    context.setFillColor(badgeColor)
    context.fillPath()
    // NSGraphicsContext already applies the representation's pixels-per-point scale.
    context.saveGState()
    context.translateBy(x: (size - bounds.width * scale) / 2, y: (size - bounds.height * scale) / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    context.addPath(outline)
    context.setBlendMode(.clear)
    context.fillPath()
    context.restoreGState()
    image.addRepresentation(rep)
}
try image.tiffRepresentation!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

// Optional offscreen contact sheet: actual size and enlarged, on light/black/dark backgrounds.
if CommandLine.arguments.count > 2 {
    let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: preview)
    let backgrounds: [NSColor] = [.white, .black, NSColor(srgbRed: 0.12, green: 0.16, blue: 0.22, alpha: 1)]
    for (index, background) in backgrounds.enumerated() {
        background.setFill()
        NSRect(x: index * 160, y: 0, width: 160, height: 128).fill()
        image.draw(in: NSRect(x: index * 160 + 72, y: 88, width: 16, height: 16))
        image.draw(in: NSRect(x: index * 160 + 56, y: 20, width: 48, height: 48))
    }
    NSGraphicsContext.restoreGraphicsState()
    try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
