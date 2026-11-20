// Renders a menu-bar icon (one character, "注" by default; "A" for English mode) to a TIFF.
// Drawn black on transparent: Info.plist sets TISIconIsTemplate, so macOS recolors it to match the menu bar.
// Usage: swift scripts/make-icon.swift <output.tiff> [character]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.tiff"
let glyph = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "注"
let reps: [NSBitmapImageRep] = [16, 32].map { size in
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.black])
    let s = text.size()
    text.draw(at: NSPoint(x: (16 - s.width) / 2, y: (16 - s.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .none, factor: 0)!
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
