import AppKit
import Testing
@testable import PaperiPlatform

struct WindowSnapshotTests {
    @MainActor @Test func snapshotStyleIsFixedForEachGesture() {
        var config = LiveConfig.GestureConfig()
        let native = SnapshotTransition(snapshotStyle: config.snapshotStyle)
        config.snapshotStyle = .simple
        let simple = SnapshotTransition(snapshotStyle: config.snapshotStyle)
        #expect(native.snapshotStyle == .native)
        #expect(simple.snapshotStyle == .simple)
        #expect(native.closeShadowClearance == 128)
        #expect(simple.closeShadowClearance == 32)
        #expect(SnapshotTransition().snapshotStyle == .native)
    }

    private func image(alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: 180, height: 140, bitsPerComponent: 8,
                                bytesPerRow: 180 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Nonopaque native framing, asymmetric padding, and spare canvas.
        context.setFillColor(CGColor(gray: 0, alpha: 0.3))
        context.fill(CGRect(x: 2, y: 10, width: 142, height: 120))
        context.clear(CGRect(x: 20, y: 40, width: 100, height: 80))
        context.setFillColor(CGColor(gray: 0.5, alpha: alpha))
        context.fill(CGRect(x: 20, y: 40, width: 100, height: 80))
        return context.makeImage()!
    }

    @Test func locatesContentWithAsymmetricShadowAndSpareCanvas() {
        #expect(WindowSnapshotGeometry.contentRect(in: image(), size: CGSize(width: 100, height: 80))
                == CGRect(x: 20, y: 20, width: 100, height: 80))
    }

    @Test func rejectsTranslucentContentAndUnexpectedScaling() {
        #expect(WindowSnapshotGeometry.contentRect(in: image(alpha: 0.5), size: CGSize(width: 100, height: 80)) == nil)
        #expect(WindowSnapshotGeometry.contentRect(in: image(), size: CGSize(width: 200, height: 160)) == nil)
        #expect(WindowSnapshotGeometry.contentRect(in: image(), size: CGSize(width: 99, height: 80)) == nil)
    }
}
