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
    private var root: CALayer?
    private var tabIndicator: GestureIndicator?
    /// Only the gesture indicator shows: the screenshots are hidden and the
    /// overlay is clear, so the live windows stay visible underneath.
    private var indicatorOnly = false
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

    func prepare(windows ids: Set<UInt32>, excluding stripIDs: Set<UInt32> = [], canvas: Rect) async throws {
        let began = ProcessInfo.processInfo.systemUptime
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
        let stripWindows = content.windows.filter { stripIDs.union(ids).contains($0.windowID) }
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
        // Windows above the overlay's level (Dock, menu bar, ...) keep drawing
        // live on top of it. Left in the capture, their translucent material
        // would blur a picture of itself: a doubled, stale Dock background.
        let above = content.windows.filter { $0.windowLayer > Self.level.rawValue }
        let background = Task {
            try await self.capture(SCContentFilter(display: display, excludingWindows: stripWindows + fadingOverlays + above),
                                   scale: scale)
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
        self.root = root
        let overlay = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = true
        overlay.backgroundColor = .black
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = Self.level
        overlay.animationBehavior = .none
        overlay.collectionBehavior = [.transient, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = root
        overlay.contentView = view
        window = overlay
        applyIndicatorOnly()
        captureMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
    }

    /// A live hint for popups and the desktop, without capturing a tiled strip.
    func prepareStandaloneIndicator() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        self.screen = screen
        screenFrame = screen.frame
        mainHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: screen.frame.size)
        root.actions = Self.noActions
        self.root = root
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frame = rows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(
                    CGPoint(x: point.x, y: mainHeight - point.y)) == true
        }).flatMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } }
        let anchor = frame ?? CGRect(x: screen.visibleFrame.minX, y: mainHeight - screen.visibleFrame.maxY,
                                     width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        captured[0] = Rect(x: anchor.minX, y: anchor.minY, width: anchor.width, height: anchor.height)
        layers[0] = CALayer()
        let overlay = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.level = .popUpMenu
        overlay.animationBehavior = .none
        overlay.collectionBehavior = [.transient, .ignoresCycle]
        let view = NSView(frame: root.frame)
        view.wantsLayer = true
        view.layer = root
        overlay.contentView = view
        window = overlay
        show()
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
    /// Bottom edge of the overlay's display, in top-left (AX) coordinates.
    var screenBottom: Double { mainHeight - Double(screenFrame.minY) }

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

    /// Stops any slide where it is on screen and returns the images' frames
    /// there (a new swipe catching a landing in flight).
    func freeze() -> [UInt32: Rect] {
        var frames: [UInt32: Rect] = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (wid, layer) in layers {
            let position = layer.presentation()?.position ?? layer.position
            layer.removeAnimation(forKey: "slide")
            layer.position = position
            let size = layer.bounds.size
            frames[wid] = Rect(x: position.x - size.width / 2 + screenFrame.minX,
                               y: mainHeight - screenFrame.minY - position.y - size.height / 2,
                               width: size.width, height: size.height)
        }
        CATransaction.commit()
        return frames
    }

    /// Adds images for `ids` that have none yet, behind the others, each at
    /// `frame(wid)` when it is ready (skipped if that is nil). Best effort:
    /// a window that cannot be captured keeps showing nothing.
    func capture(more ids: Set<UInt32>, at frame: @escaping @MainActor (UInt32) -> Rect?) async {
        let missing = ids.subtracting(layers.keys)
        guard !missing.isEmpty, let root, let screen, window != nil else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        let scale = screen.backingScaleFactor
        let tasks = content.windows.filter { missing.contains($0.windowID) }.map { item in
            (item, Task { try await self.capture(SCContentFilter(desktopIndependentWindow: item), scale: scale) })
        }
        for (item, task) in tasks {
            guard let image = try? await task.value else { continue }
            // The overlay may have gone (or been replaced) meanwhile.
            guard self.root === root, window != nil, layers[item.windowID] == nil,
                  let place = frame(item.windowID) else { continue }
            let layer = CALayer()
            layer.actions = Self.noActions
            layer.contents = image
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            layer.frame = local(Rect(x: place.x, y: place.y, width: item.frame.width, height: item.frame.height))
            layer.isHidden = indicatorOnly
            Self.addShadow(to: layer, image: image, scale: scale, active: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.insertSublayer(layer, at: 0)
            CATransaction.commit()
            layers[item.windowID] = layer
            captured[item.windowID] = Rect(x: item.frame.minX, y: item.frame.minY,
                                           width: item.frame.width, height: item.frame.height)
        }
    }

    /// Sets one image's opacity at once (finger tracking).
    func setOpacity(_ wid: UInt32, _ value: Double) {
        guard let layer = layers[wid] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fade")
        layer.opacity = Float(value)
        CATransaction.commit()
    }

    /// Animates one image's opacity from what is on screen now.
    func fade(_ wid: UInt32, to value: Double, duration: Double) {
        guard let layer = layers[wid] else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "fade")
        layer.opacity = Float(value)
        if duration > 0, from != Float(value) {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = Float(value)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "fade")
        }
        CATransaction.commit()
        CATransaction.flush()
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

    /// Slides images along `path` (frames at fraction 0…1 of the way) with
    /// `spring`'s motion, ending exactly on `frames`. Unlike `slide(to:)`,
    /// images whose straight-line distances differ still move together at
    /// the path's speed. The animation runs in the render server, so main
    /// thread work after this call cannot stall it.
    func slide(along path: (Double) -> [UInt32: Rect], to frames: [UInt32: Rect], spring: SlotSwipe.Spring) {
        let duration = spring.duration
        guard duration > 0 else { place(frames); return }
        // One sample per 120 Hz frame; the spring's own timing, so linear between them.
        let steps = max(8, Int((duration * 120).rounded(.up)))
        let samples = (0...steps).map { path(spring.fraction(at: duration * Double($0) / Double(steps))) }
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
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
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
        root = nil; tabIndicator = nil
    }

    // MARK: gesture indicator

    /// Drops the screenshots for a gesture that does not move any window;
    /// applies now or once the capture is ready.
    func showIndicatorOnly() {
        indicatorOnly = true
        applyIndicatorOnly()
    }

    private func applyIndicatorOnly() {
        guard indicatorOnly, let window, let root else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.contents = nil
        for layer in layers.values { layer.isHidden = true }
        CATransaction.commit()
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    /// Follows the fingers while a swipe acts without moving the window
    /// (closing a tab, opening a new window): the window dims and a pill
    /// moves in with the fingers, its ring filling until `threshold`, where
    /// it takes the style's colour (release acts).
    func trackIndicator(_ style: GestureIndicatorStyle, window wid: UInt32, progress: Double, threshold: Double) {
        indicator(style, for: wid)?.update(progress: progress, threshold: threshold)
    }

    /// Released early: the pill slips back out and the dim lifts.
    func retractIndicator(duration: Double) {
        tabIndicator?.retract(duration: duration)
    }

    /// The gesture changed what it does: the current pill slips away and
    /// the next `trackIndicator` brings in a new one. The dim stays where
    /// it was until the new indicator's own dim passes it.
    func replaceIndicator(duration: Double) {
        guard let old = tabIndicator else { return }
        tabIndicator = nil
        dimFloor = old.dim.opacity
        staleDim = old.dim
        old.retract(duration: duration, dim: false)
        let pill = old.pill
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { pill.removeFromSuperlayer() }
    }

    /// Dim left by a replaced indicator, shown until the next one takes over.
    private var dimFloor: Float = 0
    private var staleDim: CALayer?

    private func indicator(_ style: GestureIndicatorStyle, for wid: UInt32) -> GestureIndicator? {
        if let tabIndicator { return tabIndicator }
        guard let root, let frame = captured[wid], layers[wid] != nil else { return nil }
        let indicator = GestureIndicator(style: style, window: local(frame), cornerRadius: 10,
                                         scale: Double(screen?.backingScaleFactor ?? 2), dimFloor: dimFloor)
        staleDim?.removeFromSuperlayer(); staleDim = nil
        root.addSublayer(indicator.dim)
        root.addSublayer(indicator.pill)
        tabIndicator = indicator
        return indicator
    }

    /// Fades the overlay out over the real windows, then removes it. The
    /// transition is finished at once: a new swipe can start during the fade,
    /// and its capture leaves the fading overlay out.
    func fadeOut(duration: Double = 0.18) {
        stopFrameClock()
        guard let overlay = window else { return }
        window = nil
        layers.removeAll()
        root = nil; tabIndicator = nil
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

    private static let level = NSWindow.Level.floating

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
    enum Failure: Error { case permission, display, missingWindow, memoryBudget }
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

/// What a gesture indicator says and how it moves.
struct GestureIndicatorStyle {
    let label: String
    let armedLabel: String
    /// A plus instead of a cross in the ring.
    let plus: Bool
    let armedColor: CGColor
    /// The way the pill moves into place with the fingers, in layer space
    /// (y up): (0, 1) rises, (0, -1) comes down, (1, 0) slides right.
    var direction: CGVector

    static let minimize = GestureIndicatorStyle(label: "Minimize", armedLabel: "Release to Minimize",
        plus: false, armedColor: NSColor.systemBlue.cgColor, direction: CGVector(dx: -1, dy: 0))
    static let closeTab = GestureIndicatorStyle(label: "Close Tab", armedLabel: "Release to Close",
                                                plus: false, armedColor: NSColor.systemRed.withAlphaComponent(0.95).cgColor,
                                                direction: CGVector(dx: 0, dy: 1))
    static let newWindow = GestureIndicatorStyle(label: "New Window", armedLabel: "Release for New Window", plus: true,
                                                 armedColor: NSColor.systemBlue.withAlphaComponent(0.95).cgColor,
                                                 direction: CGVector(dx: 0, dy: -1))
    /// Down then right: the pill slides in from the left.
    static let closeTabTurn = GestureIndicatorStyle(label: "Close Tab", armedLabel: "Release to Close",
                                                    plus: false, armedColor: closeTab.armedColor,
                                                    direction: CGVector(dx: 1, dy: 0))
}

/// Gesture feedback drawn over a window's snapshot. All geometry is in the
/// overlay's (bottom-left) layer space.
@MainActor final class GestureIndicator {
    let dim = CALayer()
    let pill = CALayer()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let cross = CAShapeLayer()
    private let label = CATextLayer()
    private let rest: CGPoint
    private let style: GestureIndicatorStyle
    private var armed = false
    private let dimFloor: Float

    private static let height = 48.0
    private static let rise = 28.0
    private static let idle = NSColor(white: 0.1, alpha: 0.82).cgColor
    private static let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    /// Where the pill waits before it moves in (it travels with the fingers).
    private var away: CGPoint { offset(-Self.rise) }

    /// `rest` moved `distance` along the style's direction.
    private func offset(_ distance: Double) -> CGPoint {
        CGPoint(x: rest.x + style.direction.dx * distance, y: rest.y + style.direction.dy * distance)
    }

    init(style: GestureIndicatorStyle, window: CGRect, cornerRadius: Double, scale: Double, dimFloor: Float = 0) {
        self.style = style
        self.dimFloor = dimFloor
        let off: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(),
                                           "transform": NSNull(), "backgroundColor": NSNull(), "strokeEnd": NSNull(),
                                           "string": NSNull(), "contents": NSNull()]
        dim.frame = window
        dim.cornerRadius = cornerRadius
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = dimFloor
        dim.actions = off

        // Wide enough for the longest label.
        let text = [style.label, style.armedLabel]
            .map { ($0 as NSString).size(withAttributes: [.font: Self.font]).width }.max() ?? 100
        let size = CGSize(width: Self.height + ceil(text) + 22, height: Self.height)
        // Upper part of the window, where the tab bar is.
        rest = CGPoint(x: window.midX, y: window.maxY - min(140, max(size.height, window.height * 0.28)))
        pill.bounds = CGRect(origin: .zero, size: size)
        pill.position = away
        pill.cornerRadius = size.height / 2
        pill.backgroundColor = Self.idle
        pill.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        pill.borderWidth = 1
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.35
        pill.shadowRadius = 12
        pill.shadowOffset = CGSize(width: 0, height: -4)
        pill.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        pill.opacity = 0
        pill.actions = off

        let center = CGPoint(x: size.height / 2, y: size.height / 2)
        // From 12 o'clock, filling clockwise (layer space is y-up).
        let clockwise = CGMutablePath()
        clockwise.addArc(center: center, radius: 13, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for (layer, color) in [(track, NSColor(white: 1, alpha: 0.25)), (ring, NSColor.white)] {
            layer.frame = pill.bounds
            layer.path = clockwise
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = 2.5
            layer.lineCap = .round
            layer.actions = off
            pill.addSublayer(layer)
        }
        ring.strokeEnd = 0

        let cp = CGMutablePath()
        if style.plus {
            cp.move(to: CGPoint(x: center.x - 6, y: center.y)); cp.addLine(to: CGPoint(x: center.x + 6, y: center.y))
            cp.move(to: CGPoint(x: center.x, y: center.y - 6)); cp.addLine(to: CGPoint(x: center.x, y: center.y + 6))
        } else {
            cp.move(to: CGPoint(x: center.x - 5, y: center.y - 5)); cp.addLine(to: CGPoint(x: center.x + 5, y: center.y + 5))
            cp.move(to: CGPoint(x: center.x - 5, y: center.y + 5)); cp.addLine(to: CGPoint(x: center.x + 5, y: center.y - 5))
        }
        cross.frame = pill.bounds
        cross.path = cp
        cross.strokeColor = NSColor.white.cgColor
        cross.lineWidth = 2.5
        cross.lineCap = .round
        cross.actions = off
        pill.addSublayer(cross)

        label.frame = CGRect(x: size.height - 2, y: (size.height - 20) / 2 - 1, width: size.width - size.height - 10, height: 20)
        label.font = Self.font
        label.fontSize = 15
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .left
        label.contentsScale = scale
        label.actions = off
        label.string = style.label
        pill.addSublayer(label)
    }

    func update(progress: Double, threshold: Double) {
        let p = max(0, progress)
        let fill = min(1, p / max(0.01, threshold))
        let appear = min(1, p / max(0.01, threshold * 0.4))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.opacity = max(dimFloor, Float(0.12 + 0.28 * fill) * Float(appear))
        pill.opacity = Float(appear)
        pill.position = offset(-Self.rise * (1 - fill) + max(0, p - threshold) * 12)
        let scale = 0.9 + 0.1 * fill
        pill.transform = CATransform3DMakeScale(scale, scale, 1)
        ring.strokeEnd = fill
        CATransaction.commit()
        setArmed(p >= threshold)
    }

    private func setArmed(_ value: Bool) {
        guard value != armed else { return }
        armed = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = value ? style.armedLabel : style.label
        pill.backgroundColor = value ? style.armedColor : Self.idle
        CATransaction.commit()
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = value ? Self.idle : style.armedColor
        flash.toValue = value ? style.armedColor : Self.idle
        flash.duration = 0.12
        pill.add(flash, forKey: "armed")
    }

    func retract(duration: Double, dim fadesDim: Bool = true) {
        let ease = CAMediaTimingFunction(name: .easeOut)
        var moves: [(CALayer, String, Any)] = [(pill, "opacity", 0.0), (pill, "position", NSValue(point: away))]
        if fadesDim { moves.append((dim, "opacity", 0.0)) }
        for (layer, key, to) in moves {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            animation.toValue = to
            animation.duration = max(0.01, duration)
            animation.timingFunction = ease
            layer.setValue(to, forKeyPath: key)
            layer.add(animation, forKey: "retract-" + key)
        }
        CATransaction.flush()
    }
}
