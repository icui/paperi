import Foundation

/// Pure reducer for slot-based trackpad swipe gestures. No OS effects.
///
/// A three-finger horizontal swipe moves the strip by at most one slot either
/// way. Progress is signed: positive progress moves toward `.right` (revealing
/// the right neighbour), negative moves toward `.left`.
///
/// With `closeTravel` set, an upward vertical lock instead tracks a close:
/// progress runs from 0 (in place) to 1 (the focused window off the top).
public struct SlotSwipe: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case detecting(accDx: Double, accDy: Double, startTime: Double)
        case active(rawProgress: Double, clampedProgress: Double, velocity: Double, lastTime: Double)
        case closing(rawProgress: Double, clampedProgress: Double, velocity: Double, lastTime: Double)
        case completed(Decision)
        case cancelled
    }

    public enum Decision: Equatable, Sendable {
        case commit(Direction)
        case close
        case snapBack
    }

    public enum Action: Equatable, Sendable {
        case started
        case updated(progress: Double)
        case closeStarted
        case closeUpdated(progress: Double)
        case finished(Decision)
        case cancelled
    }

    public struct Configuration: Equatable, Sendable {
        public var travel: Double
        public var commitThreshold: Double
        public var flickVelocity: Double
        public var lockThreshold: Double
        public var invert: Bool
        /// Upward finger travel (fraction of the trackpad height) that takes
        /// the focused window fully off screen. `nil`: vertical swipes cancel.
        public var closeTravel: Double?

        public init(travel: Double = 0.4,
                    commitThreshold: Double = 0.5,
                    flickVelocity: Double = 1.5,
                    lockThreshold: Double = 0.015,
                    invert: Bool = false,
                    closeTravel: Double? = nil) {
            self.travel = travel
            self.commitThreshold = commitThreshold
            self.flickVelocity = flickVelocity
            self.lockThreshold = lockThreshold
            self.invert = invert
            self.closeTravel = closeTravel
        }
    }

    public var config: Configuration
    public private(set) var state: State

    public init(config: Configuration = Configuration()) {
        self.config = config
        self.state = .idle
    }

    /// Smooth rubber-band resistance beyond `limit`.
    public static func rubberBand(_ progress: Double, limit: Double = 1.0) -> Double {
        guard progress.isFinite else { return 0 }
        let sign = progress < 0 ? -1.0 : 1.0
        let absP = abs(progress)
        if absP <= limit { return progress }
        let excess = absP - limit
        let resisted = limit + (excess * 0.25) / (1.0 + excess * 0.5)
        return sign * resisted
    }

    /// At most eight slots per second, even if input arrives in one large jump.
    public static let maximumVisualSpeed = 8.0

    public static func advanceVisualProgress(_ current: Double, toward target: Double, elapsed: Double) -> Double {
        guard current.isFinite, target.isFinite, elapsed.isFinite, elapsed > 0 else { return current }
        // Never catch up a stalled run loop in one visible jump.
        let step = maximumVisualSpeed * min(elapsed, 1.0 / 30.0)
        return current + min(step, max(-step, target - current))
    }

    /// Visual time constant: absorbs touch reports that beat against the
    /// display (one unit is a whole column or window height) at the cost of
    /// ~16 ms of lag.
    public static let visualSmoothing = 0.016

    /// Like `advanceVisualProgress`, but approaches the target exponentially
    /// so frames without new input still move a little and the next one does
    /// not jump. The speed limit still applies.
    public static func followVisualProgress(_ current: Double, toward target: Double, elapsed: Double,
                                            timeConstant: Double = visualSmoothing) -> Double {
        guard current.isFinite, target.isFinite, elapsed.isFinite, elapsed > 0, timeConstant > 0 else { return current }
        let dt = min(elapsed, 1.0 / 30.0)
        let eased = current + (target - current) * (1 - exp(-dt / timeConstant))
        // Snap the last fraction of a point's worth instead of creeping forever.
        let next = abs(target - eased) < 1e-4 ? target : eased
        return advanceVisualProgress(current, toward: next, elapsed: dt)
    }

    /// Bezier control points for a settle that starts at `speed` (progress
    /// per second, along the motion) and decelerates to rest over `distance`
    /// in `duration`. Matching the on-screen speed avoids a lurch at release.
    public static func settleCurve(speed: Double, distance: Double, duration: Double) -> (Double, Double, Double, Double) {
        guard speed.isFinite, distance > 0, duration > 0 else { return (0, 0, 0.58, 1) }
        // Initial slope of the normalised curve; ease-out's is about 1.7.
        let slope = min(4, max(0, speed * duration / distance))
        let x1 = 0.25
        return (x1, min(1, x1 * slope), 0.4, 1)
    }

    /// Duration for a settle that starts at `speed` and stops: about twice
    /// distance / speed, within the usual settle bounds.
    public static func settleDuration(distance: Double, speed: Double, base: Double) -> Double {
        let usual = settleDuration(distance: distance, base: base)
        guard speed.isFinite, speed > 0.01, distance > 0 else { return usual }
        return min(usual, max(0.12, 1.8 * distance / speed, 2 * distance / maximumVisualSpeed))
    }

    /// The ease-out curve peaks below twice its average speed. Budget enough
    /// time for that peak too, so releasing cannot bypass the tracking limit.
    public static func settleDuration(distance: Double, base: Double) -> Double {
        guard distance.isFinite, base.isFinite, distance > 0 else { return 0 }
        return max(0.16, min(0.4, max(0.16, base)) * sqrt(min(1, distance)),
                   2 * distance / maximumVisualSpeed)
    }

    public mutating func begin(at time: Double) {
        state = .detecting(accDx: 0, accDy: 0, startTime: time)
    }

    public mutating func move(dx: Double, dy: Double, at time: Double) -> Action? {
        guard dx.isFinite, dy.isFinite, time.isFinite else { return nil }
        switch state {
        case .idle, .completed, .cancelled:
            return nil

        case .detecting(let accX, let accY, let start):
            let newX = accX + dx
            let newY = accY + dy
            let absX = abs(newX)
            let absY = abs(newY)
            if max(absX, absY) >= config.lockThreshold {
                if absX > 1.2 * absY {
                    // Locked horizontal! As for closes, the shown progress
                    // starts from rest here instead of jumping the lead-in.
                    let dirFactor = config.invert ? 1.0 : -1.0
                    let rawProg = (newX * dirFactor) / max(0.01, config.travel)
                    origin = max(-0.5, min(0.5, rawProg))
                    let clamped = Self.rubberBand(Self.shown(rawProg, origin: origin))
                    let dt = max(1.0 / 120.0, time - start)
                    let vel = rawProg / dt
                    state = .active(rawProgress: rawProg, clampedProgress: clamped, velocity: vel, lastTime: time)
                    return .started
                } else if absY > 1.2 * absX {
                    // Touch y grows upwards. Only an upward swipe closes.
                    guard let closeTravel = config.closeTravel, newY > 0 else {
                        state = .cancelled
                        return .cancelled
                    }
                    // Raw progress (release decisions) counts the travel
                    // before the lock; the shown progress starts from rest
                    // there, as one close unit is a whole window height and
                    // the lock distance at once would jump tens of points.
                    let rawProg = newY / max(0.01, closeTravel)
                    let dt = max(1.0 / 120.0, time - start)
                    origin = min(0.5, rawProg)
                    state = .closing(rawProgress: rawProg, clampedProgress: shownClose(rawProg),
                                     velocity: rawProg / dt, lastTime: time)
                    return .closeStarted
                } else {
                    // Keep accumulating ambiguous diagonal motion until an axis wins.
                    state = .detecting(accDx: newX, accDy: newY, startTime: start)
                    return nil
                }
            } else {
                state = .detecting(accDx: newX, accDy: newY, startTime: start)
                return nil
            }

        case .active(let rawProg, _, let lastVel, let lastTime):
            let dirFactor = config.invert ? 1.0 : -1.0
            let deltaProg = (dx * dirFactor) / max(0.01, config.travel)
            let newRaw = rawProg + deltaProg
            let clamped = Self.rubberBand(Self.shown(newRaw, origin: origin))
            guard time > lastTime else { return nil }
            let dt = time - lastTime
            let instantVel = deltaProg / max(1.0 / 120.0, dt)
            // A time-based filter behaves consistently across trackpad report rates.
            let weight = 1 - exp(-dt / 0.025)
            let newVel = lastVel + weight * (instantVel - lastVel)
            state = .active(rawProgress: newRaw, clampedProgress: clamped, velocity: newVel, lastTime: time)
            return .updated(progress: clamped)

        case .closing(let rawProg, _, let lastVel, let lastTime):
            let deltaProg = dy / max(0.01, config.closeTravel ?? 1)
            let newRaw = rawProg + deltaProg
            guard time > lastTime else { return nil }
            let dt = time - lastTime
            let instantVel = deltaProg / max(1.0 / 120.0, dt)
            let weight = 1 - exp(-dt / 0.025)
            let newVel = lastVel + weight * (instantVel - lastVel)
            let clamped = shownClose(newRaw)
            state = .closing(rawProgress: newRaw, clampedProgress: clamped, velocity: newVel, lastTime: time)
            return .closeUpdated(progress: clamped)
        }
    }

    /// Raw progress at the axis lock.
    private var origin = 0.0

    /// Shown progress: 0 at the lock (`origin`), meeting raw progress at
    /// ±1 and beyond, linear in between on each side. Removes the lead-in
    /// jump without changing where a full step lands, in either direction.
    public static func shown(_ raw: Double, origin: Double) -> Double {
        guard raw.isFinite, origin.isFinite, abs(origin) < 1 else { return raw }
        if abs(raw) >= 1 { return raw }
        return raw >= origin ? (raw - origin) / (1 - origin) : (raw - origin) / (1 + origin)
    }

    private func shownClose(_ raw: Double) -> Double { Self.closeBand(Self.shown(raw, origin: origin)) }

    /// Close progress: never below the window's place, resisting past fully off.
    public static func closeBand(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return max(0, rubberBand(progress))
    }

    /// Shared release rule: a long enough aligned flick, or enough travel
    /// without a fast retreat.
    private func releases(raw: Double, clamped: Double, velocity: Double, lastTime: Double, at time: Double) -> Bool {
        // Stationary touches produce no move events. Fade stale velocity out
        // over 100 ms so a hold before release cannot act as a flick.
        let releaseVelocity = velocity * max(0, 1 - max(0, time - lastTime) / 0.1)
        let aligned = releaseVelocity * raw > 0
        // Require intentional travel as well as speed. A tiny twitch must
        // not jump a whole slot, nor should reversing select an unseen slot.
        let flick = abs(raw) >= 0.12 && aligned && abs(releaseVelocity) >= config.flickVelocity
        let retreating = releaseVelocity * raw < 0 && abs(releaseVelocity) >= config.flickVelocity
        return flick || (abs(clamped) >= config.commitThreshold && !retreating)
    }

    public mutating func end(at time: Double) -> Decision {
        switch state {
        case .active(let rawProg, _, let vel, let lastTime):
            // Decide on the whole finger travel, including the lead-in.
            let decision: Decision = releases(raw: rawProg, clamped: Self.rubberBand(rawProg), velocity: vel, lastTime: lastTime, at: time)
                ? (rawProg > 0 ? .commit(.right) : .commit(.left)) : .snapBack
            state = .completed(decision)
            return decision

        case .closing(let rawProg, _, let vel, let lastTime):
            // A swipe dragged back below its start is not a close. Decide on
            // the whole finger travel, including the lead-in to the lock.
            let decision: Decision = rawProg > 0
                && releases(raw: rawProg, clamped: Self.closeBand(rawProg), velocity: vel, lastTime: lastTime, at: time)
                ? .close : .snapBack
            state = .completed(decision)
            return decision

        case .detecting:
            let decision = Decision.snapBack
            state = .completed(decision)
            return decision

        case .idle, .completed, .cancelled:
            return .snapBack
        }
    }

    public mutating func cancel() {
        state = .cancelled
    }
}
