import Foundation

/// Pure reducer for slot-based trackpad swipe gestures. No OS effects.
///
/// A three-finger horizontal swipe moves the strip by at most one slot either
/// way. Progress is signed: positive progress moves toward `.right` (revealing
/// the right neighbour), negative moves toward `.left`.
///
/// With `closeTravel` set, an upward vertical lock instead tracks a close:
/// progress runs from 0 (in place) to 1 (the focused window off the top).
/// With `pullTravel` set, a downward lock tracks a pull the same way
/// (progress grows as the fingers move down); the caller chooses the action.
/// With `turnTravel` set too, a pull can turn left or right. Progress then
/// follows that direction, and the pull no longer acts.
///
/// A swipe may start with the strip already off its column: a new swipe that
/// catches a landing in flight (`startOffset`, set by `anchor`). Progress is
/// then measured from the column nearest to where the strip was caught, and
/// a release settles on that column or one of its neighbours.
public struct SlotSwipe: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case detecting(accDx: Double, accDy: Double, startTime: Double)
        case active(rawProgress: Double, clampedProgress: Double, velocity: Double, lastTime: Double)
        case closing(rawProgress: Double, clampedProgress: Double, velocity: Double, lastTime: Double)
        case pulling(rawProgress: Double, clampedProgress: Double, velocity: Double, lastTime: Double)
        case turning(rawProgress: Double, clampedProgress: Double, velocity: Double, lastTime: Double)
        case completed(Decision)
        case cancelled
    }

    public enum Decision: Equatable, Sendable {
        case commit(Direction)
        case close
        case pull
        case turn
        case snapBack
    }

    public enum Action: Equatable, Sendable {
        case started
        case updated(progress: Double)
        case closeStarted
        case closeUpdated(progress: Double)
        case pullStarted
        case pullUpdated(progress: Double)
        case turnStarted
        case turnUpdated(progress: Double)
        case finished(Decision)
        case cancelled
    }

    public struct Configuration: Equatable, Sendable {
        public var travel: Double
        /// Finger travel for a full step towards the left / right neighbour
        /// when it differs from `travel`. The caller sets these from how far
        /// the strip scrolls each way, so the strip moves the same distance
        /// per unit of finger travel whatever the column widths.
        public var travelLeft: Double?
        public var travelRight: Double?
        public var commitThreshold: Double
        public var flickVelocity: Double
        public var lockThreshold: Double
        public var invert: Bool
        /// Upward finger travel (fraction of the trackpad height) that takes
        /// the focused window fully off screen. `nil`: vertical swipes cancel.
        public var closeTravel: Double?
        /// Downward finger travel for a full pull (e.g. the focused window off
        /// the bottom). `nil`: downward swipes cancel.
        public var pullTravel: Double?
        /// Horizontal finger travel for a full turn out of a pull.
        /// `nil`: a pull cannot turn.
        public var turnTravel: Double?
        /// Where the strip was, in slots from this swipe's column, when the
        /// swipe began (a landing it caught); 0 for a strip at rest.
        public var startOffset: Double

        public init(travel: Double = 0.4,
                    commitThreshold: Double = 0.5,
                    flickVelocity: Double = 1.5,
                    lockThreshold: Double = 0.015,
                    invert: Bool = false,
                    closeTravel: Double? = nil,
                    pullTravel: Double? = nil,
                    turnTravel: Double? = nil,
                    startOffset: Double = 0,
                    travelLeft: Double? = nil,
                    travelRight: Double? = nil) {
            self.travel = travel
            self.travelLeft = travelLeft
            self.travelRight = travelRight
            self.commitThreshold = commitThreshold
            self.flickVelocity = flickVelocity
            self.lockThreshold = lockThreshold
            self.invert = invert
            self.closeTravel = closeTravel
            self.pullTravel = pullTravel
            self.turnTravel = turnTravel
            self.startOffset = startOffset
        }
    }

    public private(set) var turnDirection: Direction = .right

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

    /// A critically damped spring carrying a released swipe to its target:
    /// `distance` (progress units) still to go, entered at `speed` towards
    /// the target (negative: moving away). The motion continues at exactly
    /// the release speed and slows onto the target without passing it.
    public struct Spring: Equatable, Sendable {
        public let distance: Double
        public let speed: Double
        public let omega: Double
        /// When what is left drops below `tolerance`; the caller ends there.
        public let duration: Double

        public static let tolerance = 0.001

        /// `response`: seconds for a spring starting from rest to cover 99%.
        public init(distance: Double, speed: Double, response: Double) {
            let d = distance.isFinite ? max(0, distance) : 0
            let base = 6.64 / max(0.05, response.isFinite ? response : 0.22)
            let v = speed.isFinite ? speed : 0
            // Too fast to stop in time at the usual stiffness: stiffen until
            // it just arrives (a plain exponential) rather than overshoot.
            let omega = d > 1e-9 ? max(base, v / d) : base
            self.distance = d
            self.omega = omega
            // Moving away, it turns round within about a fifth of the distance.
            self.speed = max(v, -omega * d)
            var t = 0.0
            if d > 1e-9 {
                let step = 1.0 / 240
                while t < 1, t * omega < 1 || abs(Self.remaining(d, self.speed, omega, t)) > Self.tolerance { t += step }
            }
            duration = t
        }

        private static func remaining(_ d: Double, _ v: Double, _ omega: Double, _ t: Double) -> Double {
            (d + (omega * d - v) * t) * exp(-omega * t)
        }

        /// Fraction of the distance covered `elapsed` seconds in: 0 at the
        /// start, 1 from `duration` on. Negative while still moving away.
        public func fraction(at elapsed: Double) -> Double {
            guard distance > 1e-9, elapsed.isFinite, elapsed < duration else { return 1 }
            if elapsed <= 0 { return 0 }
            return 1 - Self.remaining(distance, speed, omega, elapsed) / distance
        }

        /// Speed towards the target `elapsed` seconds in, progress per second.
        public func velocity(at elapsed: Double) -> Double {
            guard distance > 1e-9, elapsed.isFinite, elapsed < duration else { return 0 }
            let t = max(0, elapsed)
            return (speed + omega * (omega * distance - speed) * t) * exp(-omega * t)
        }
    }

    public mutating func begin(at time: Double) {
        state = .detecting(accDx: 0, accDy: 0, startTime: time)
        turnX = 0; turnY = 0
        turnDirection = .right
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
                    let rawProg = advance(0, by: newX * (config.invert ? 1.0 : -1.0))
                    origin = max(-0.5, min(0.5, rawProg))
                    let clamped = Self.rubberBand(config.startOffset + Self.shown(rawProg, origin: origin))
                    let dt = max(1.0 / 120.0, time - start)
                    let vel = rawProg / dt
                    state = .active(rawProgress: rawProg, clampedProgress: clamped, velocity: vel, lastTime: time)
                    return .started
                } else if absY > 1.2 * absX {
                    // Touch y grows upwards: up closes, down pulls.
                    guard let travel = newY > 0 ? config.closeTravel : config.pullTravel else {
                        state = .cancelled
                        return .cancelled
                    }
                    // Raw progress (release decisions) counts the travel
                    // before the lock; the shown progress starts from rest
                    // there, as one unit is a whole window height and the
                    // lock distance at once would jump tens of points.
                    let rawProg = abs(newY) / max(0.01, travel)
                    let dt = max(1.0 / 120.0, time - start)
                    origin = min(0.5, rawProg)
                    if newY > 0 {
                        state = .closing(rawProgress: rawProg, clampedProgress: shownClose(rawProg),
                                         velocity: rawProg / dt, lastTime: time)
                        return .closeStarted
                    }
                    state = .pulling(rawProgress: rawProg, clampedProgress: shownClose(rawProg),
                                        velocity: rawProg / dt, lastTime: time)
                    return .pullStarted
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
            let newRaw = advance(rawProg, by: dx * (config.invert ? 1.0 : -1.0))
            let deltaProg = newRaw - rawProg
            let clamped = Self.rubberBand(config.startOffset + Self.shown(newRaw, origin: origin))
            guard time > lastTime else { return nil }
            let dt = time - lastTime
            let instantVel = deltaProg / max(1.0 / 120.0, dt)
            // A time-based filter behaves consistently across trackpad report rates.
            let weight = 1 - exp(-dt / 0.025)
            let newVel = lastVel + weight * (instantVel - lastVel)
            state = .active(rawProgress: newRaw, clampedProgress: clamped, velocity: newVel, lastTime: time)
            return .updated(progress: clamped)

        case .closing(let rawProg, _, let lastVel, let lastTime):
            guard let next = vertical(rawProg, lastVel, lastTime, delta: dy / max(0.01, config.closeTravel ?? 1), at: time)
            else { return nil }
            state = .closing(rawProgress: next.raw, clampedProgress: next.shown, velocity: next.velocity, lastTime: time)
            return .closeUpdated(progress: next.shown)

        case .pulling(let rawProg, _, let lastVel, let lastTime):
            if let turnTravel = config.turnTravel, let turn = turnLock(dx: dx, dy: dy) {
                // Shown from rest at the turn, like the other locks.
                turnDirection = turn < 0 ? .left : .right
                let raw = abs(turn) / max(0.01, turnTravel)
                origin = min(0.5, raw)
                state = .turning(rawProgress: raw, clampedProgress: shownClose(raw), velocity: 0, lastTime: time)
                return .turnStarted
            }
            guard let next = vertical(rawProg, lastVel, lastTime, delta: -dy / max(0.01, config.pullTravel ?? 1), at: time)
            else { return nil }
            state = .pulling(rawProgress: next.raw, clampedProgress: next.shown, velocity: next.velocity, lastTime: time)
            return .pullUpdated(progress: next.shown)

        case .turning(let rawProg, _, let lastVel, let lastTime):
            guard let next = vertical(rawProg, lastVel, lastTime, delta: dx * (turnDirection == .left ? -1 : 1) / max(0.01, config.turnTravel ?? 1), at: time)
            else { return nil }
            state = .turning(rawProgress: next.raw, clampedProgress: next.shown, velocity: next.velocity, lastTime: time)
            return .turnUpdated(progress: next.shown)
        }
    }

    /// Finger travel for a full step on the side `raw` is on.
    private func travel(side raw: Double) -> Double {
        max(0.01, (raw < 0 ? config.travelLeft : config.travelRight) ?? config.travel)
    }

    /// Horizontal progress after `fingers` more travel (signed, along
    /// progress). The two sides may need different travel for a full step;
    /// crossing the start keeps the fingers' position continuous.
    private func advance(_ raw: Double, by fingers: Double) -> Double {
        let position = raw * travel(side: raw) + fingers
        return position / travel(side: position)
    }

    /// One close, pull or turn update; `delta` is in progress units.
    private func vertical(_ raw: Double, _ lastVel: Double, _ lastTime: Double, delta: Double, at time: Double)
        -> (raw: Double, shown: Double, velocity: Double)? {
        guard time > lastTime else { return nil }
        let newRaw = raw + delta
        let dt = time - lastTime
        let instantVel = delta / max(1.0 / 120.0, dt)
        let weight = 1 - exp(-dt / 0.025)
        return (newRaw, shownClose(newRaw), lastVel + weight * (instantVel - lastVel))
    }

    /// Raw progress at the axis lock.
    private var origin = 0.0

    /// Finger travel since a pull last moved mostly down.
    private var turnX = 0.0, turnY = 0.0

    /// Horizontal travel a turn needs: a deliberate move, well past the
    /// sideways drift of fingers slowing down or lifting off after a pull.
    public static let turnLockMultiple = 4.0

    /// How strongly horizontal travel must dominate vertical travel to turn
    /// (within about 27° of horizontal).
    public static let turnDominance = 2.0

    /// Collects pull motion until it turns clearly left or right, returning
    /// signed horizontal travel. Mostly vertical motion resets collection.
    private mutating func turnLock(dx: Double, dy: Double) -> Double? {
        turnX += dx
        turnY += dy
        let lock = config.lockThreshold * Self.turnLockMultiple
        if abs(turnY) >= lock, abs(turnY) > 1.2 * abs(turnX) { turnX = 0; turnY = 0; return nil }
        guard abs(turnX) >= lock, abs(turnX) > Self.turnDominance * abs(turnY) else { return nil }
        defer { turnX = 0; turnY = 0 }
        return turnX
    }

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

    /// Travel below which release speed is ignored: a tiny twitch must not
    /// act, however fast.
    public static let flickTravel = 0.12

    /// Seconds of coasting credited to the release speed. A release commits
    /// when travel plus coast reaches the commit threshold, so at the least
    /// travel that counts, `flickVelocity` is exactly the speed that commits,
    /// and longer swipes need proportionally less.
    private var coastTime: Double {
        max(0, config.commitThreshold - Self.flickTravel) / max(0.01, config.flickVelocity)
    }

    /// How much further the release speed would carry, in progress units.
    private func coast(travel: Double, velocity: Double, lastTime: Double, at time: Double) -> Double {
        // Stationary touches produce no move events. Fade stale velocity out
        // over 100 ms so a hold before release cannot act as a flick.
        let releaseVelocity = velocity * max(0, 1 - max(0, time - lastTime) / 0.1)
        return abs(travel) >= Self.flickTravel ? releaseVelocity * coastTime : 0
    }

    /// Release rule for closes, pulls and turns: where the fingers were
    /// heading reaches the commit threshold. Moving back fast cancels.
    private func releases(raw: Double, clamped: Double, velocity: Double, lastTime: Double, at time: Double) -> Bool {
        clamped + coast(travel: raw, velocity: velocity, lastTime: lastTime, at: time) >= config.commitThreshold
    }

    public mutating func end(at time: Double) -> Decision {
        switch state {
        case .active(let rawProg, _, let vel, let lastTime):
            let decision = horizontalDecision(raw: rawProg, velocity: vel, lastTime: lastTime, at: time)
            state = .completed(decision)
            return decision

        case .closing(let rawProg, _, let vel, let lastTime), .pulling(let rawProg, _, let vel, let lastTime),
             .turning(let rawProg, _, let vel, let lastTime):
            // A swipe dragged back past its start does nothing. Decide on
            // the whole finger travel, including the lead-in to the lock.
            // A turn's flick counts only travel after the turn locked: its
            // lead-in alone already passes the flick minimum, so a sideways
            // twitch at lift-off would otherwise commit it.
            var flickTravel = rawProg
            if case .turning = state { flickTravel = Self.shown(rawProg, origin: origin) }
            let commits = rawProg > 0
                && releases(raw: flickTravel, clamped: Self.closeBand(rawProg), velocity: vel, lastTime: lastTime, at: time)
            let decision: Decision
            switch state {
            case .closing: decision = commits ? .close : .snapBack
            case .turning: decision = commits ? .turn : .snapBack
            default: decision = commits ? .pull : .snapBack
            }
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

    /// Sets where the strip was when this swipe began (see `startOffset`),
    /// e.g. once the swipe has locked onto a landing it caught.
    public mutating func anchor(offset: Double) {
        config.startOffset = offset.isFinite ? offset : 0
        if case .active(let raw, _, let velocity, let lastTime) = state {
            state = .active(rawProgress: raw, clampedProgress: Self.rubberBand(config.startOffset + Self.shown(raw, origin: origin)),
                            velocity: velocity, lastTime: lastTime)
        }
    }

    /// A swipe heading far enough its own way steps one slot that way from
    /// this swipe's column, even if the strip has not passed that column yet:
    /// two quick swipes move two columns. Otherwise the strip settles where
    /// it was heading: past the commit threshold of a neighbour it goes
    /// there, else back to its column. Speed never selects the side the
    /// strip is not on.
    private func horizontalDecision(raw: Double, velocity: Double, lastTime: Double, at time: Double) -> Decision {
        let coast = coast(travel: raw, velocity: velocity, lastTime: lastTime, at: time)
        if coast * raw > 0, abs(raw + coast) >= config.commitThreshold {
            return .commit(raw > 0 ? .right : .left)
        }
        // Decide on the whole finger travel, including the lead-in.
        let position = config.startOffset + raw
        let rest = Self.rubberBand(position) + coast
        guard abs(rest) >= config.commitThreshold, rest * position > 0 else { return .snapBack }
        return .commit(position > 0 ? .right : .left)
    }

    /// Sets the finger travel for a full step each way once the caller knows
    /// how far the strip scrolls, keeping the fingers' position.
    public mutating func retarget(travelLeft: Double?, travelRight: Double?) {
        guard case .active(let raw, _, let velocity, let lastTime) = state else {
            config.travelLeft = travelLeft; config.travelRight = travelRight; return
        }
        let fingers = raw * travel(side: raw), lead = origin * travel(side: origin)
        let scale = travel(side: raw)
        config.travelLeft = travelLeft; config.travelRight = travelRight
        let next = fingers / travel(side: fingers)
        origin = max(-0.5, min(0.5, lead / travel(side: lead)))
        state = .active(rawProgress: next, clampedProgress: Self.rubberBand(config.startOffset + Self.shown(next, origin: origin)),
                        velocity: velocity * scale / travel(side: next), lastTime: lastTime)
    }

    // MARK: catching a landing

    /// The column (-1, 0 or 1 from a landing's own) a new swipe takes over
    /// from at `position`: the nearest one there is.
    public static func nearestSlot(_ position: Double, available: Set<Int>) -> Int {
        guard position.isFinite else { return 0 }
        return available.min { abs(Double($0) - position) < abs(Double($1) - position) } ?? 0
    }

    /// Which part of a caught swipe's path `progress` lies on. The images
    /// start at the caught frames (`offset`); from there they move to the
    /// swipe's own column (`toColumn`, fraction of the way), or straight on
    /// to the neighbour beyond (`fromCaught`). Past its column they move from
    /// there to the other neighbour (`fromColumn`). Fractions may exceed 1
    /// past a neighbour.
    public enum PathLeg: Equatable, Sendable {
        case toColumn(Double)
        case fromColumn(Direction, Double)
        case fromCaught(Direction, Double)
    }

    public static func leg(_ progress: Double, offset: Double) -> PathLeg {
        let side: Direction = progress < 0 ? .left : .right
        guard offset.isFinite, abs(offset) > 1e-9, progress.isFinite else { return .fromColumn(side, abs(progress)) }
        if progress * offset <= 0 {
            return progress == 0 ? .toColumn(1) : .fromColumn(side, abs(progress))
        }
        if abs(progress) <= abs(offset) { return .toColumn(1 - progress / offset) }
        let remaining = 1 - abs(offset)
        return .fromCaught(side, remaining > 1e-6 ? (abs(progress) - abs(offset)) / remaining : 1)
    }
}
