// Renders the SomedayX app icon (white bookmark on black, X style) into an
// .iconset folder: swift make_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: ~80% body with rounded corners.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).fill()
    NSColor(white: 1, alpha: 0.12).setStroke()
    let ring = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    ring.lineWidth = max(1, s / 256)
    ring.stroke()

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: (s - g.width) / 2, y: (s - g.height) / 2, width: g.width, height: g.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
