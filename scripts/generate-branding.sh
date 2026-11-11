#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
source_file="$(mktemp -t paperi-branding).swift"
trap 'rm -f "$source_file"' EXIT
cat Sources/Paperi/BrandIcon.swift scripts/generate-branding.swift > "$source_file"
cat >> "$source_file" <<'SWIFT'
for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20 * scale, pixelsHigh: 18 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    MainActor.assumeIsolated {
        BrandIcon.menuBar().draw(in: NSRect(x: 0, y: 0, width: 20 * scale, height: 18 * scale))
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("MenuBar\(scale == 2 ? "@2x" : "").png"))
}
SWIFT
swift "$source_file"
iconutil -c icns assets/branding/Paperi.iconset -o assets/branding/Paperi.icns
