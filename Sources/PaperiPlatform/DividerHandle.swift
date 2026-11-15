import AppKit
import PaperiCore

/// The grab handle over the gap between two tiled windows (gap resize).
///
/// Nothing is drawn while the pointer is elsewhere: gaps are thin slivers
/// of wallpaper, and a mark at every gap on every display would compete with
/// window content and have to follow each scroll and animation frame. With
/// the pointer anywhere along a gap (within `hoverWidth` across it, so also
/// just inside a window's edge) a pill fades in at the gap's middle after a
/// short dwell, so sweeping across a gap does not flash. Shared row boundaries
/// take clicks across their full width; column boundaries take clicks only
/// in the central segment. While dragging, two arrows indicate the resize axis.
///
/// The panel never activates Paperi, so the focused window keeps focus.
@MainActor final class DividerHandle {
    /// Pointer down on the handle, in screen coordinates (top-left origin).
    var onBegin: ((Double, Double) -> Void)?
    var onDrag: ((Double, Double) -> Void)?
    var onEnd: (() -> Void)?

    /// Across the gap: the band where the pointer shows the handle.
    static let hoverWidth = 24.0
    /// The grab segment, centred on the gap's middle.
    static let grabWidth = 16.0
    static let grabLength = 120.0
    static let dwell = 0.12

    private var panel: NSPanel?
    private let arrows = CAShapeLayer()
    private var morph: CGFloat = 0
    private var morphTask: Task<Void, Never>?
    private var region: DividerRegion?
    private var fadeTask: Task<Void, Never>?
    private var fadeTarget = false
    private var ownsCursor = false
    private(set) var dragging = false
    /// A trackpad resize is showing the arrows: the pointer is elsewhere, so
    /// the handle neither takes the cursor nor clicks.
    private var tracking = false
    var isShown: Bool { panel?.isVisible == true }

    /// Shows (or moves) the handle at the middle of `region`; `inGrab` is
    /// whether the pointer is over the grab segment (resize cursor).
    func show(_ region: DividerRegion, inGrab: Bool, updateVisibility: Bool = true) {
        let panel = self.panel ?? make()
        self.panel = panel
        let vertical = region.divider.isVertical
        // Whole points, so the window server does not shift the panel and
        // the pill is placed against the gap's exact centre.
        let showsArrows = dragging || morph > 0
        let hit = region.hitRegion(hitWidth: showsArrows ? 56 : Self.grabWidth, length: Self.grabLength)
        let left = hit.x.rounded(.down), top = hit.y.rounded(.down)
        let width = (hit.x + hit.width).rounded(.up) - left, height = (hit.y + hit.height).rounded(.up) - top
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let frame = NSRect(x: left, y: primaryHeight - top - height, width: width, height: height)
        self.region = region
        if panel.frame != frame { panel.setFrame(frame, display: false) }

        let g = region.gap
        let across = CGFloat(region.position - (vertical ? left : top))
        let along = CGFloat(vertical ? g.y + g.height / 2 - top : g.x + g.width / 2 - left)
        let extent = CGFloat(vertical ? height : width)
        let length = min(80, max(16, extent - 8))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arrows.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let path = CGMutablePath()
        // Two separated chevrons leave the gap open and indicate the resize
        // axis without pretending to mark either app's asynchronously drawn edge.
        func point(_ cross: CGFloat, _ offset: CGFloat) -> CGPoint {
            vertical ? CGPoint(x: across + cross, y: along + offset)
                : CGPoint(x: along + offset, y: across + cross)
        }
        for sign: CGFloat in [-1, 1] {
            path.move(to: point(sign * 14 * morph, -(length / 2 * (1 - morph) + 6 * morph)))
            path.addLine(to: point(sign * 21 * morph, 0))
            path.addLine(to: point(sign * 14 * morph, length / 2 * (1 - morph) + 6 * morph))
        }
        arrows.path = path
        arrows.strokeColor = CGColor(gray: 1, alpha: 1)
        arrows.lineWidth = 4 - morph
        CATransaction.commit()

        if updateVisibility {
            if !tracking && (inGrab || dragging) {
                (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                ownsCursor = true
            } else { releaseCursor() }
        }
        // Commit drag feedback without waiting for another rendering pass.
        if dragging {
            panel.displayIfNeeded()
            CATransaction.flush()
        }
        guard updateVisibility else { return }
        if dragging {
            fadeTask?.cancel(); fadeTask = nil
            fadeTarget = true
            panel.alphaValue = 1
            panel.ignoresMouseEvents = tracking
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else {
            fade(visible: true)
        }
    }

    /// Interpolate matching three-point paths so a rapid release reverses
    /// from the current shape. Window position is never animated.
    private func animateMorph(to target: CGFloat) {
        morphTask?.cancel()
        let from = morph
        morphTask = Task { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            do {
                while true {
                    try Task.checkCancellation()
                    guard let self else { return }
                    let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.14)
                    let eased = CGFloat(progress * progress * (3 - 2 * progress))
                    self.morph = from + (target - from) * eased
                    if let region = self.region {
                        self.show(region, inGrab: false, updateVisibility: false)
                    }
                    if progress >= 1 { self.morphTask = nil; return }
                    try await Task.sleep(for: .milliseconds(8))
                }
            } catch { return }
        }
    }

    /// Shows the resize arrows (at the next `show`) for a resize driven by
    /// the trackpad rather than by dragging the handle.
    func beginTracking() {
        guard !dragging else { return }
        dragging = true; tracking = true
        animateMorph(to: 1)
    }

    func endTracking() {
        guard tracking else { return }
        tracking = false; dragging = false
        animateMorph(to: 0)
        hide()
    }

    func hide() {
        guard !dragging else { return }
        releaseCursor()
        fade(visible: false)
    }

    /// Match the bottom dots: a reversible 160 ms smoothstep fade.
    private func fade(visible: Bool) {
        guard let panel, fadeTarget != visible else { return }
        fadeTask?.cancel()
        fadeTarget = visible
        panel.ignoresMouseEvents = !visible
        let fresh = !panel.isVisible
        if visible, fresh {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        let from = panel.alphaValue
        let to: CGFloat = visible ? 1 : 0
        fadeTask = Task { [weak self, weak panel] in
            do {
                if visible, fresh { try await Task.sleep(for: .seconds(Self.dwell)) }
                let started = ProcessInfo.processInfo.systemUptime
                while true {
                    try Task.checkCancellation()
                    guard let panel else { return }
                    let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.16)
                    let eased = progress * progress * (3 - 2 * progress)
                    panel.alphaValue = from + (to - from) * CGFloat(eased)
                    if progress >= 1 {
                        if !visible {
                            panel.orderOut(nil)
                            self?.region = nil
                        }
                        self?.fadeTask = nil
                        return
                    }
                    try await Task.sleep(for: .milliseconds(8))
                }
            } catch { return }
        }
    }

    /// Hands the cursor back once the pointer leaves the grab segment; the
    /// app under it sets its own (e.g. its edge-resize cursor) on the next move.
    private func releaseCursor() {
        guard ownsCursor else { return }
        ownsCursor = false
        NSCursor.arrow.set()
    }

    private func make() -> NSPanel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Set explicitly so the transparent panel still takes clicks.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = GripView()
        view.owner = self
        view.wantsLayer = true
        // Barely there, so the window server never treats the panel as a hole.
        view.layer?.backgroundColor = CGColor(gray: 0, alpha: 1.0 / 255)
        arrows.fillColor = nil
        arrows.lineWidth = 3
        arrows.lineCap = .round
        arrows.lineJoin = .round
        arrows.shadowColor = CGColor(gray: 0, alpha: 1)
        arrows.shadowOpacity = 0.65
        arrows.shadowRadius = 2
        arrows.shadowOffset = .zero
        view.layer?.addSublayer(arrows)
        panel.contentView = view
        return panel
    }

    fileprivate func mouse(_ event: NSEvent, phase: Int) {
        let point = NSEvent.mouseLocation
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let (x, y) = (Double(point.x), primaryHeight - Double(point.y))
        switch phase {
        case 0:
            dragging = true
            animateMorph(to: 1)
            // Keep the overlay responsive while its shape transforms.
            if let region { show(region, inGrab: true) }
            onBegin?(x, y)
        case 1:
            if dragging { onDrag?(x, y) }
        default:
            guard dragging else { return }
            dragging = false
            animateMorph(to: 0)
            onEnd?()
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Top-left origin, matching the layout's screen coordinates.
    private final class GripView: NSView {
        weak var owner: DividerHandle?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { owner?.mouse(event, phase: 0) }
        override func mouseDragged(with event: NSEvent) { owner?.mouse(event, phase: 1) }
        override func mouseUp(with event: NSEvent) { owner?.mouse(event, phase: 2) }
    }
}
