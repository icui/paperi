import AppKit

/// Native screenshots include framing outside the AX window rectangle. Locate
/// the opaque content on the two centre lines rather than assuming symmetric
/// shadow padding. Translucent/nonstandard windows must use the fallback path.
enum WindowSnapshotGeometry {
    static func contentRect(in image: CGImage, size: CGSize) -> CGRect? {
        let width = image.width, height = image.height
        let expectedWidth = Int(size.width.rounded()), expectedHeight = Int(size.height.rounded())
        guard width >= expectedWidth, height >= expectedHeight,
              expectedWidth > 0, expectedHeight > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Bitmap rows follow the image's top-to-bottom ordering here.
        func opaque(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] == 255 }
        guard let left = (0..<width).first(where: { opaque($0, height / 2) }),
              let right = (0..<width).last(where: { opaque($0, height / 2) }),
              let top = (0..<height).first(where: { opaque(width / 2, $0) }),
              let bottom = (0..<height).last(where: { opaque(width / 2, $0) }),
              right - left + 1 == expectedWidth, bottom - top + 1 == expectedHeight else { return nil }
        return CGRect(x: left, y: top, width: expectedWidth, height: expectedHeight)
    }
}
