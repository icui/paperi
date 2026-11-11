import AppKit
import QuartzCore
@preconcurrency import ScreenCaptureKit
import PaperiCore

/// Screenshot compositor for the swipe gesture. Captures never leave memory.
/// An opaque capture of everything except the strip masks the real windows
/// while their images move; the caller moves the real windows once underneath,
/// slides the images onto the frames the real windows actually took, then fades out.
@MainActor final class SnapshotTransition {
    private var window: NSWindow?
    private var layers: [UInt32: CALayer] = [:]
    private var screenFrame = CGRect.zero
    private var screen: NSScreen?
    private var frameClock: FrameClock?
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
        self.screen = screen
        let scale = screen.backingScaleFactor
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: screen.frame.size)
        root.masksToBounds = true
        root.actions = Self.noActions
        // Submit all screenshots together. Serial capture adds one display-frame
        // wait per window, leaving short swipes invisible until finger release.
        let fadingOverlays = content.windows.filter { Self.fading.contains($0.windowID) }
        let background = Task {
            try await self.capture(SCContentFilter(display: display, excludingWindows: windows + fadingOverlays), scale: scale)
        }
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
        // The key window is the frontmost app's frontmost window; only it gets
        // macOS's larger active shadow.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let key = windows.first { $0.owningApplication?.processID == frontPID }?.windowID
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
            Self.addShadow(to: layer, image: image, scale: scale, active: item.windowID == key)
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

    /// Captures exclude window shadows (a shadowed capture is squeezed into the
    /// window's frame), so draw an approximation of the system shadow instead of
    /// letting it vanish while the overlay is up. A path keeps it cheap to move.
    private static func addShadow(to layer: CALayer, image: CGImage, scale: Double, active: Bool) {
        let radius = cornerRadius(of: image) / scale
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = active ? 0.4 : 0.22
        layer.shadowRadius = active ? 16 : 7
        layer.shadowOffset = CGSize(width: 0, height: active ? -8 : -3)
    }

    /// A rounded corner of radius r first turns opaque on the diagonal at
    /// r * (1 - 1/sqrt 2); read that from the top-left corner of the capture.
    private static func cornerRadius(of image: CGImage) -> Double {
        let n = min(64, image.width, image.height)
        guard n > 0, let corner = image.cropping(to: CGRect(x: 0, y: 0, width: n, height: n)),
              let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        context.draw(corner, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let first = (0..<n).first(where: { data[($0 * n + $0) * 4 + 3] >= 128 }) else { return 0 }
        return Double(first) / (1 - 1 / 2.0.squareRoot())
    }

    var isShown: Bool { window != nil }

    /// Top edge of the overlay's display, in top-left (AX) coordinates.
    var screenTop: Double { mainHeight - Double(screenFrame.maxY) }

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

    /// Slides images along `path` (frames at fraction 0…1 of the way), ending
    /// exactly on `frames`. Unlike `slide(to:)`, images whose straight-line
    /// distances differ still move together at the path's speed.
    func slide(along path: (Double) -> [UInt32: Rect], to frames: [UInt32: Rect], duration: Double) {
        guard duration > 0 else { place(frames); return }
        let steps = 32
        let samples = (0...steps).map { path(Double($0) / Double(steps)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (wid, layer) in layers {
            guard let frame = frames[wid] else { continue }
            let from = layer.presentation()?.position ?? layer.position
            let to = center(frame)
            layer.removeAnimation(forKey: "slide")
            layer.position = to
            var values = samples.map { $0[wid].map(center) ?? from }
            values[0] = from
            values[steps] = to
            guard values.contains(where: { $0 != to }) else { continue }
            let animation = CAKeyframeAnimation(keyPath: "position")
            animation.values = values.map { NSValue(point: $0) }
            animation.calculationMode = .linear
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "slide")
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Calls `tick` once per refresh of the overlay's display, just before the
    /// frame is composed. Image moves made there land on every frame evenly;
    /// a free-running timer beats against the refresh and moves them unevenly.
    func startFrameClock(_ tick: @escaping @MainActor (CADisplayLink) -> Void) {
        guard frameClock == nil, let screen else { return }
        frameClock = FrameClock(screen: screen, tick: tick)
    }

    func stopFrameClock() {
        frameClock?.invalidate()
        frameClock = nil
    }

    func hide() {
        stopFrameClock()
        window?.orderOut(nil)
        window = nil
        layers.removeAll()
    }

    /// Fades the overlay out over the real windows, then removes it. The
    /// transition is finished at once: a new swipe can start during the fade,
    /// and its capture leaves the fading overlay out.
    func fadeOut(duration: Double = 0.18) {
        stopFrameClock()
        guard let overlay = window else { return }
        window = nil
        layers.removeAll()
        guard duration > 0 else { overlay.orderOut(nil); return }
        let number = CGWindowID(overlay.windowNumber)
        Self.fading.insert(number)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                overlay.orderOut(nil)
                Self.fading.remove(number)
            }
        })
    }

    /// Overlays still fading out; later captures must not see them.
    private static var fading: Set<CGWindowID> = []

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

/// Display link target. The link retains its target until invalidated.
@MainActor private final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private let tick: @MainActor (CADisplayLink) -> Void

    init(screen: NSScreen, tick: @escaping @MainActor (CADisplayLink) -> Void) {
        self.tick = tick
        super.init()
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) { tick(link) }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}
