// usage: swift make-icon.swift <out.iconset dir>   then: iconutil -c icns <dir>
import AppKit

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.98, green: 0.55, blue: 0.30, alpha: 1), NSColor(red: 0.55, green: 0.25, blue: 0.85, alpha: 1)])!
        .draw(in: path, angle: -60)
    let cfg = NSImage.SymbolConfiguration(pointSize: 400 * s, weight: .semibold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "books.vertical.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let r = NSRect(x: tile.midX - sym.size.width / 2, y: tile.midY - sym.size.height / 2, width: sym.size.width, height: sym.size.height)
        sym.draw(in: r)
    }
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
