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
              let horizontal = opaqueSpan(in: image, rect: CGRect(x: 0, y: height / 2, width: width, height: 1)),
              let vertical = opaqueSpan(in: image, rect: CGRect(x: width / 2, y: 0, width: 1, height: height)),
              horizontal.count == expectedWidth, vertical.count == expectedHeight else { return nil }
        return CGRect(x: horizontal.lowerBound, y: vertical.lowerBound, width: expectedWidth, height: expectedHeight)
    }

    /// Crop before drawing: allocating and converting a full Retina screenshot
    /// just to read these lines adds milliseconds and megabytes per window.
    private static func opaqueSpan(in image: CGImage, rect: CGRect) -> Range<Int>? {
        let width = Int(rect.width), height = Int(rect.height)
        guard let strip = image.cropping(to: rect),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Honour the context's actual row stride for vertical strips.
        let count = max(width, height)
        let stride = width == 1 ? context.bytesPerRow : 4
        guard let first = (0..<count).first(where: { pixels[$0 * stride + 3] == 255 }),
              let last = (0..<count).last(where: { pixels[$0 * stride + 3] == 255 }) else { return nil }
        return first..<(last + 1)
    }
}
