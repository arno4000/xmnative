// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024
    // macOS icon grid: 824pt body centred on a 1024 canvas, ~185pt corner radius.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
                        NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)])!
        .draw(in: path, angle: -90)

    // Soft accent glow behind the glyph
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let glow = NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.55), .clear])!
    glow.draw(fromCenter: NSPoint(x: 512 * s, y: 470 * s), radius: 0,
              toCenter: NSPoint(x: 512 * s, y: 470 * s), radius: 430 * s, options: [])
    NSGraphicsContext.current?.restoreGraphicsState()

    let cfg = NSImage.SymbolConfiguration(pointSize: 470 * s, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let r = NSRect(x: (1024 * s - sym.size.width) / 2, y: (1024 * s - sym.size.height) / 2 - 10 * s,
                       width: sym.size.width, height: sym.size.height)
        sym.draw(in: r)
    }
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(size: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
