import Foundation

/// A short, interruptible prediction. Cubic Hermite motion starts at the
/// displayed position/speed and stops at the forecast if no report follows.
public struct SwipeTrajectory: Equatable, Sendable {
    public let start: Double
    public let target: Double
    public let initialVelocity: Double
    public let duration: Double

    public init(start: Double, target: Double, velocity: Double, duration: Double = 0.06) {
        self.start = start
        self.target = target
        self.duration = max(0.001, duration)
        // Bound exceptional corrections, especially at reversal or stop.
        let limit = 3 * abs(target - start) / self.duration
        self.initialVelocity = min(limit, max(-limit, velocity))
    }

    public func position(at elapsed: Double) -> Double {
        let t = min(1, max(0, elapsed / duration))
        let d = target - start
        return start + d * t * t * (3 - 2 * t)
            + initialVelocity * duration * t * (1 - t) * (1 - t)
    }

    public func velocity(at elapsed: Double) -> Double {
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let t = elapsed / duration
        return (target - start) * 6 * t * (1 - t) / duration
            + initialVelocity * (1 - 4 * t + 3 * t * t)
    }
}
