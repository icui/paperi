import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import PaperiCore

/// Shift + trackpad swipe resizes the focused tiled window. Horizontal
/// motion moves its right edge; against the display's right edge the strip
/// scrolls and the window grows leftward instead. Vertical motion (stacked
/// windows only) moves the gap below the window, or above the bottom one.
/// The edge follows the fingers until they lift. Frames are written like a
/// gap drag's, which also learns the apps' size limits.
extension LiveManager {
    struct EdgeResize {
        /// Finger travel since the fingers landed, in trackpad fractions (y up).
        var dx = 0.0, dy = 0.0
        /// The resize axis, once the fingers have moved far enough to pick one.
        var vertical: Bool?
        /// The edge resize is under way (a `dividerDrag` is moving it), or
        /// there was nothing to resize and the fingers are ignored.
        var started = false
        var refused = false
        /// Where the edge was, and the finger travel along the axis, at the start.
        var origin = 0.0
        var travel = 0.0
    }
    /// Finger travel, as a fraction of the trackpad, that picks the axis.
    static let edgeResizeLock = 0.012
    /// Edge travel for fingers crossing the whole trackpad, in display widths
    /// (horizontally) or heights (vertically).
    static let edgeResizeGain = 1.0

    static var shiftHeld: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) }

    /// Takes over the touch sequence: from now on it resizes, never swipes,
    /// and nothing else (refreshes, commands, the tray) changes the strip
    /// until every finger has lifted, even if some lift and return meanwhile.
    func beginEdgeResize() {
        edgeResize = EdgeResize()
        (touchSource as? EventTapTouchSource)?.holdsSequence = true
        log("edge resize armed")
    }

    func moveEdgeResize(dx: Double, dy: Double) {
        guard var state = edgeResize else { return }
        state.dx += dx; state.dy += dy
        var locking = false
        if state.vertical == nil, max(abs(state.dx), abs(state.dy)) >= Self.edgeResizeLock {
            state.vertical = abs(state.dy) > abs(state.dx)
            locking = true
        }
        edgeResize = state
        guard let vertical = state.vertical else { return }
        let travel = vertical ? state.dy : state.dx
        if !state.started {
            // Waits for a running animation; a resize then starts where the
            // fingers are, rather than jumping by the travel so far.
            guard !state.refused, !gestureBlockedByAnimation else { return }
            guard let drag = edgeResizeDrag(vertical: vertical) else {
                state.refused = true; edgeResize = state; return
            }
            state.started = true
            state.origin = drag.along
            state.travel = locking ? 0 : travel
            edgeResize = state
            dividerHandle.beginTracking()
            startDividerDrag(drag)
        }
        guard var current = dividerDrag, let session = coordinator.sessions[current.space] else { return }
        let moved = (travel - state.travel) * Self.edgeResizeGain
        // Trackpad y points up; screen y points down.
        current.along = state.origin + (vertical ? -moved * session.canvas.height : moved * session.canvas.width)
        dividerDrag = current
        layOutDividerDrag()
    }

    func endEdgeResize() {
        guard let state = edgeResize else { return }
        edgeResize = nil
        (touchSource as? EventTapTouchSource)?.holdsSequence = false
        // Reconcile what was held off: through the drag's end if it began.
        if state.started, dividerDrag != nil { finishDividerDrag() } else { scheduleRefresh() }
    }

    /// The edge of the focused window of the strip under the pointer (or of
    /// the focused window's strip) to move along the axis, as a drag.
    func edgeResizeDrag(vertical: Bool) -> DividerDrag? {
        guard running, !paused, AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0,
              drag == nil, dividerDrag == nil, DisplayArrangement.currentProblem() == nil,
              !pointerOverUnmanagedSpace(), let ctx = pointerContext() ?? focusedContext() else { return nil }
        let session = ctx.session, space = ctx.space, layout = session.state.layout
        guard coordinator.display(forSpace: space)?.activeSpaceID == space, !session.state.interactionSuppressed,
              let focused = layout.focused,
              let edge = layout.resizeEdge(of: focused, vertical: vertical),
              let region = try? layout.region(of: edge, in: session.canvas, gap: options.gap) else {
            log("edge resize: nothing to resize \(vertical ? "vertically" : "horizontally")")
            return nil
        }
        return DividerDrag(space: space, divider: edge, grab: 0, along: region.position)
    }
}
