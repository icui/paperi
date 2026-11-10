import AppKit
import QuartzCore
@preconcurrency import ScreenCaptureKit
import PaperiCore

/// Experimental, one-shot compositor. Captures never leave memory.
/// An opaque background capture masks the real windows while their images move.
@MainActor final class SnapshotTransition {
    private var window: NSWindow?
    private var layers: [UInt32: CALayer] = [:]
    private var screenFrame = CGRect.zero
    private(set) var captureMS = 0.0
    private(set) var textureBytes = 0

    func prepare(frames: [UInt32: Rect], canvas: Rect) async throws {
        let began = ProcessInfo.processInfo.systemUptime
        guard frames.count <= 12 else { throw Failure.tooManyWindows }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw Failure.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let screen = NSScreen.screens.first(where: { screen in
            let height = NSScreen.screens.first?.frame.height ?? 0
            let ax = CGRect(x: screen.frame.minX, y: height - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
            return ax.contains(CGPoint(x: canvas.x + canvas.width / 2, y: canvas.y + canvas.height / 2))
        }), let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.display }
        let windows = content.windows.filter { frames[$0.windowID] != nil }
        guard windows.count == frames.count else { throw Failure.missingWindow }
        screenFrame = screen.frame
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: screen.frame.size)
        root.masksToBounds = true
        let background = try await capture(SCContentFilter(display: display, excludingWindows: windows), scale: screen.backingScaleFactor)
        try Task.checkCancellation()
        root.contents = background
        // ScreenCaptureKit's list is front to back; compose back to front.
        for item in windows.reversed() {
            guard let frame = frames[item.windowID] else { continue }
            let image = try await capture(SCContentFilter(desktopIndependentWindow: item), scale: screen.backingScaleFactor)
            try Task.checkCancellation()
            let layer = CALayer()
            layer.contents = image
            layer.contentsGravity = .resize
            layer.frame = local(frame)
            root.addSublayer(layer)
            layers[item.windowID] = layer
        }
        let overlay = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = true
        overlay.backgroundColor = .black
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .floating
        overlay.animationBehavior = .none
        overlay.collectionBehavior = [.transient, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = root
        overlay.contentView = view
        window = overlay
        captureMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
    }

    private func capture(_ filter: SCContentFilter, scale: Double) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = max(1, Int(filter.contentRect.width * scale))
        config.height = max(1, Int(filter.contentRect.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let bytes = config.width * config.height * 4
        guard textureBytes + bytes <= 256 * 1024 * 1024 else { throw Failure.memoryBudget }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        textureBytes += image.bytesPerRow * image.height
        return image
    }

    func show(targets: [UInt32: Rect], duration: Double) {
        window?.orderFrontRegardless()
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for (wid, layer) in layers {
            guard let target = targets[wid] else { continue }
            let end = local(target)
            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = NSValue(point: layer.position)
            animation.toValue = NSValue(point: CGPoint(x: end.midX, y: end.midY))
            layer.position = CGPoint(x: end.midX, y: end.midY)
            layer.add(animation, forKey: "focusPosition")
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        layers.removeAll()
    }

    private func local(_ frame: Rect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: frame.x - screenFrame.minX,
                      y: height - frame.y - frame.height - screenFrame.minY,
                      width: frame.width, height: frame.height)
    }
    enum Failure: Error { case permission, display, missingWindow, tooManyWindows, memoryBudget }
}
