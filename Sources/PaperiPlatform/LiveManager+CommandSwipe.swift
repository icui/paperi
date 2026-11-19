import AppKit
import CoreGraphics
import PaperiCore

/// ⌘ + trackpad swipe runs the directional command assigned to its
/// direction (`gesture.cmdSwipeLeft/Right/Up/Down`). Optional: with all four
/// set to `none`, ⌘ + swipes are ordinary swipes. The first movement picks
/// the direction; a pill follows the fingers, and releasing past
/// `commitThreshold` (or with a flick) runs the command. Shift takes
/// precedence (edge resize).
extension LiveManager {
    struct CommandSwipe {
        /// Finger travel since the fingers landed, in trackpad fractions (y up).
        var dx = 0.0, dy = 0.0
        /// The direction, once the fingers have moved far enough to pick one.
        var slot: LiveConfig.SwipeSlot?
        var overlay: SnapshotTransition?
        /// Progress along the picked direction (1 = full travel), and when
        /// it was last sampled, for flick detection.
        var progress = 0.0
        var velocity = 0.0
        var sampled = ProcessInfo.processInfo.systemUptime
    }

    /// Finger travel, as a fraction of the trackpad, that picks the direction.
    static let commandSwipeLock = 0.012

    static var commandHeld: Bool { CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand) }

    /// ⌘ is down and at least one ⌘ + swipe direction is assigned.
    var commandSwipeArmed: Bool { options.config.gesture.commandSwipesEnabled && Self.commandHeld }

    func beginCommandSwipe() {
        commandSwipe = CommandSwipe()
        (touchSource as? EventTapTouchSource)?.holdsSequence = true
    }

    func moveCommandSwipe(dx: Double, dy: Double) {
        guard var state = commandSwipe else { return }
        state.dx += dx; state.dy += dy
        let gesture = options.config.gesture
        if state.slot == nil {
            guard max(abs(state.dx), abs(state.dy)) >= Self.commandSwipeLock else { commandSwipe = state; return }
            let slot: LiveConfig.SwipeSlot = abs(state.dy) > abs(state.dx)
                ? (state.dy > 0 ? .cmdSwipeUp : .cmdSwipeDown)
                : (state.dx > 0 ? .cmdSwipeRight : .cmdSwipeLeft)
            state.slot = slot
            log("command swipe: \(slot.rawValue) → \(gesture.action(slot).rawValue)")
        }
        guard let slot = state.slot else { return }
        let action = gesture.action(slot)
        let vertical = slot == .cmdSwipeUp || slot == .cmdSwipeDown
        let sign = slot == .cmdSwipeUp || slot == .cmdSwipeRight ? 1.0 : -1.0
        let travel = vertical ? gesture.travel : gesture.columnTravel
        let progress = max(0, (vertical ? state.dy : state.dx) * sign / max(travel, 0.01))
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - state.sampled
        if elapsed > 0 {
            let instant = (progress - state.progress) / elapsed
            state.velocity = state.velocity == 0 ? instant : state.velocity * 0.6 + instant * 0.4
        }
        state.progress = progress
        state.sampled = now
        if action != .none {
            if state.overlay == nil {
                let overlay = SnapshotTransition()
                overlay.prepareStandaloneIndicator()
                state.overlay = overlay
            }
            var style = directionalIndicatorStyle(action, slot: slot)
            style.direction = vertical ? CGVector(dx: 0, dy: sign) : CGVector(dx: sign, dy: 0)
            state.overlay?.trackIndicator(style, window: 0, progress: progress, threshold: gesture.commitThreshold)
        }
        commandSwipe = state
    }

    func endCommandSwipe(commit: Bool) {
        guard let state = commandSwipe else { return }
        commandSwipe = nil
        (touchSource as? EventTapTouchSource)?.holdsSequence = false
        state.overlay?.fadeOut()
        let gesture = options.config.gesture
        guard commit, let slot = state.slot, gesture.action(slot) != .none else { return }
        // The vertical swipes' release rule: travel plus the coast the release
        // speed would add, ignoring speed below `flickTravel` and speed that
        // has faded during a hold (no move events arrive while still).
        let held = ProcessInfo.processInfo.systemUptime - state.sampled
        let release = state.velocity * max(0, 1 - held / 0.1)
        let coastTime = max(0, gesture.commitThreshold - SlotSwipe.flickTravel) / max(0.01, gesture.flickVelocity)
        let coast = state.progress >= SlotSwipe.flickTravel ? max(0, release) * coastTime : 0
        guard state.progress + coast >= gesture.commitThreshold else { return }
        performStandalonePull(gesture.action(slot), slot: slot)
    }
}
