import AppKit
import CoreText

// Center the visible glyph outlines, not the font's baseline/line box.
let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 32, nil)
// Two characters side by side, laid out by ink width so the pair reads as one badge.
let characters: [UniChar] = [0x8F7B, 0x8A00] // 轻言
let gap: CGFloat = 2
let outline = CGMutablePath()
var cursor: CGFloat = 0
for character in characters {
    var source = character
    var glyph: CGGlyph = 0
    precondition(CTFontGetGlyphsForCharacters(font, &source, &glyph, 1))
    guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { fatalError("Missing icon glyph") }
    let ink = path.boundingBoxOfPath
    let placement = CGAffineTransform(translationX: cursor - ink.minX, y: 0)
    outline.addPath(path, transform: placement)
    cursor += ink.width + gap
}
let bounds = outline.boundingBoxOfPath
// The menu bar sets the height; the badge widens to fit both characters at full height.
let height: CGFloat = 16
let padding: CGFloat = 1.5
let scale = (height - 2 * padding) / bounds.height
let width = (bounds.width * scale + 2 * padding).rounded(.up)
let badgeColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
let image = NSImage(size: NSSize(width: width, height: height))
// TISIconIsTemplate in Info.plist makes the system input menu tint this alpha mask.
// NSImage metadata alone is not preserved in TIFF files.
image.isTemplate = true

// Explicit point sizes avoid the previous 32-point canvas and baseline offset.
for density in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * density, pixelsHigh: Int(height) * density,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    // Solid badge with a genuinely transparent glyph, not white lettering.
    context.addPath(CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1),
        cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
    context.setFillColor(badgeColor)
    context.fillPath()
    // NSGraphicsContext already applies the representation's pixels-per-point scale.
    context.saveGState()
    context.translateBy(x: (width - bounds.width * scale) / 2, y: (height - bounds.height * scale) / 2)
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
        image.draw(in: NSRect(x: CGFloat(index * 160) + (160 - width) / 2, y: 88, width: width, height: height))
        image.draw(in: NSRect(x: CGFloat(index * 160) + (160 - width * 3) / 2, y: 20, width: width * 3, height: height * 3))
    }
    NSGraphicsContext.restoreGraphicsState()
    try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
