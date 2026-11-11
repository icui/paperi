// Run with: ./scripts/generate-branding.sh
import AppKit

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("assets/branding")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
func render(size: Int, name: String, draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
func appMark() {
    let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208)
    color(0.16, 0.15, 0.14).setFill()
    background.fill()
    // A quiet card carousel: the active sheet sits forward of two peers.
    color(0.57, 0.54, 0.49).setFill()
    for x in [232.0, 552.0] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 368, width: 240, height: 328), xRadius: 36, yRadius: 36).fill()
    }
    let active = NSBezierPath(roundedRect: NSRect(x: 372, y: 336, width: 280, height: 392), xRadius: 40, yRadius: 40)
    color(0.16, 0.15, 0.14).setStroke()
    active.lineWidth = 16
    active.stroke()
    color(0.96, 0.94, 0.89).setFill()
    active.fill()
    // A single warm accent recalls the gesture area beneath webOS cards.
    color(0.85, 0.43, 0.24).setFill()
    NSBezierPath(roundedRect: NSRect(x: 416, y: 246, width: 192, height: 24), xRadius: 12, yRadius: 12).fill()
}
let iconset = output.appendingPathComponent("Paperi.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale, name: "Paperi.iconset/" + name, draw: appMark)
    }
}
try render(size: 1024, name: "Paperi.png", draw: appMark)

// Render the actual runtime template, so exported assets stay in sync.
// BrandIcon.swift is compiled alongside this generator by generate-branding.sh.
