import AppKit
import QuartzCore
@preconcurrency import ScreenCaptureKit
import PaperiCore

/// Screenshot compositor for the swipe gesture. Captures never leave memory.
/// An opaque capture of everything except the strip masks the real windows
/// while their images move; the caller moves the real windows once underneath,
/// slides the images onto the frames the real windows actually took, then hides.
@MainActor final class SnapshotTransition {
    private var window: NSWindow?
    private var layers: [UInt32: CALayer] = [:]
    private var screenFrame = CGRect.zero
    private var mainHeight = 0.0
    /// Frames of the captured windows as ScreenCaptureKit saw them (top-left
    /// origin). The images start here, so they line up with the real windows
    /// even if a cached survey frame is stale.
    private(set) var captured: [UInt32: Rect] = [:]
    private(set) var captureMS = 0.0
    private(set) var textureBytes = 0

    func prepare(windows ids: Set<UInt32>, canvas: Rect) async throws {
        let began = ProcessInfo.processInfo.systemUptime
        guard ids.count <= 12 else { throw Failure.tooManyWindows }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw Failure.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        mainHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        guard let screen = NSScreen.screens.first(where: { screen in
            let ax = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
            return ax.contains(CGPoint(x: canvas.x + canvas.width / 2, y: canvas.y + canvas.height / 2))
        }), let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.display }
        let windows = content.windows.filter { ids.contains($0.windowID) }
        guard windows.count == ids.count else { throw Failure.missingWindow }
        screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: screen.frame.size)
        root.masksToBounds = true
        root.actions = Self.noActions
        // Submit all screenshots together. Serial capture adds one display-frame
        // wait per window, leaving short swipes invisible until finger release.
        let background = Task { try await self.capture(SCContentFilter(display: display, excludingWindows: windows), scale: scale) }
        let windowCaptures = windows.reversed().map { item in
            (item, Task { try await self.capture(SCContentFilter(desktopIndependentWindow: item), scale: scale) })
        }
        defer {
            background.cancel()
            for (_, task) in windowCaptures { task.cancel() }
        }
        root.contents = try await background.value
        root.contentsScale = scale
        try Task.checkCancellation()
        // ScreenCaptureKit's list is front to back; compose back to front.
        for (item, task) in windowCaptures {
            let frame = Rect(x: item.frame.minX, y: item.frame.minY, width: item.frame.width, height: item.frame.height)
            let image = try await task.value
            try Task.checkCancellation()
            let layer = CALayer()
            layer.actions = Self.noActions
            layer.contents = image
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            layer.frame = local(frame)
            root.addSublayer(layer)
            layers[item.windowID] = layer
            captured[item.windowID] = frame
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
        // Reserve before suspension so concurrent captures share the same budget.
        textureBytes += bytes
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        textureBytes += image.bytesPerRow * image.height - bytes
        return image
    }

    var isShown: Bool { window != nil }

    func show() {
        // Submit the fully composed layer tree before exposing the opaque window.
        // Otherwise its first display can briefly show the black backing store.
        window?.displayIfNeeded()
        CATransaction.flush()
        window?.orderFrontRegardless()
    }

    /// Moves images immediately (finger tracking); cancels any running slide.
    func place(_ frames: [UInt32: Rect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (wid, layer) in layers {
            guard let frame = frames[wid] else { continue }
            layer.removeAnimation(forKey: "slide")
            layer.position = center(frame)
        }
        CATransaction.commit()
    }

    /// Slides images from wherever they are on screen now (including mid-slide).
    func slide(to frames: [UInt32: Rect], duration: Double, easeIn: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (wid, layer) in layers {
            guard let frame = frames[wid] else { continue }
            let from = layer.presentation()?.position ?? layer.position
            let to = center(frame)
            layer.removeAnimation(forKey: "slide")
            layer.position = to
            guard duration > 0, from != to else { continue }
            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = NSValue(point: from)
            animation.toValue = NSValue(point: to)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: easeIn ? .easeInEaseOut : .easeOut)
            layer.add(animation, forKey: "slide")
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        layers.removeAll()
    }

    private func center(_ frame: Rect) -> CGPoint {
        let rect = local(frame)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func local(_ frame: Rect) -> CGRect {
        CGRect(x: frame.x - screenFrame.minX,
               y: mainHeight - frame.y - frame.height - screenFrame.minY,
               width: frame.width, height: frame.height)
    }

    private static let noActions: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(),
                                                            "contents": NSNull(), "frame": NSNull()]
    enum Failure: Error { case permission, display, missingWindow, tooManyWindows, memoryBudget }
}
