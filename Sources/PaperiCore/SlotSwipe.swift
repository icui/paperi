import Foundation

/// Pure reducer for slot-based trackpad swipe gestures. No OS effects.
///
/// A three-finger horizontal swipe moves the strip by at most one slot either
/// way. Progress is signed: positive progress moves toward `.right` (revealing
/// the right neighbour), negative moves toward `.left`.
public struct SlotSwipe: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case detecting(accDx: Double, accDy: Double, startTime: Double)
        case active(rawProgress: Double, clampedProgress: Double, velocity: Double, lastTime: Double)
        case completed(Decision)
        case cancelled
    }

    public enum Decision: Equatable, Sendable {
        case commit(Direction)
        case snapBack
    }

    public enum Action: Equatable, Sendable {
        case started
        case updated(progress: Double)
        case finished(Decision)
        case cancelled
    }

    public struct Configuration: Equatable, Sendable {
        public var travel: Double
        public var commitThreshold: Double
        public var flickVelocity: Double
        public var lockThreshold: Double
        public var invert: Bool

        public init(travel: Double = 0.4,
                    commitThreshold: Double = 0.5,
                    flickVelocity: Double = 1.5,
                    lockThreshold: Double = 0.015,
                    invert: Bool = false) {
            self.travel = travel
            self.commitThreshold = commitThreshold
            self.flickVelocity = flickVelocity
            self.lockThreshold = lockThreshold
            self.invert = invert
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
                    // Locked horizontal!
                    let dirFactor = config.invert ? 1.0 : -1.0
                    let rawProg = (newX * dirFactor) / max(0.01, config.travel)
                    let clamped = Self.rubberBand(rawProg)
                    let dt = max(1.0 / 120.0, time - start)
                    let vel = rawProg / dt
                    state = .active(rawProgress: rawProg, clampedProgress: clamped, velocity: vel, lastTime: time)
                    return .started
                } else if absY > 1.2 * absX {
                    state = .cancelled
                    return .cancelled
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
            let clamped = Self.rubberBand(newRaw)
            guard time > lastTime else { return nil }
            let dt = time - lastTime
            let instantVel = deltaProg / max(1.0 / 120.0, dt)
            // A time-based filter behaves consistently across trackpad report rates.
            let weight = 1 - exp(-dt / 0.025)
            let newVel = lastVel + weight * (instantVel - lastVel)
            state = .active(rawProgress: newRaw, clampedProgress: clamped, velocity: newVel, lastTime: time)
            return .updated(progress: clamped)
        }
    }

    public mutating func end(at time: Double) -> Decision {
        switch state {
        case .active(let rawProg, let clampedProg, let vel, let lastTime):
            let decision: Decision
            // Stationary touches produce no move events. Fade stale velocity out
            // over 100 ms so a hold before release cannot act as a flick.
            let releaseVelocity = vel * max(0, 1 - max(0, time - lastTime) / 0.1)
            let distance = abs(rawProg)
            let aligned = releaseVelocity * rawProg > 0
            // Require intentional travel as well as speed. A tiny twitch must
            // not jump a whole slot, nor should reversing select an unseen slot.
            let flick = distance >= 0.12 && aligned
                && abs(releaseVelocity) >= config.flickVelocity
            let retreating = releaseVelocity * rawProg < 0
                && abs(releaseVelocity) >= config.flickVelocity
            if flick || (abs(clampedProg) >= config.commitThreshold && !retreating) {
                decision = rawProg > 0 ? .commit(.right) : .commit(.left)
            } else {
                decision = .snapBack
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
}
