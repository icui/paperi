import Testing
@testable import PaperiCore

struct SwipeTrajectoryTests {
    @Test func startsAtDisplayedPositionAndSpeed() {
        let motion = SwipeTrajectory(start: 0.2, target: 0.5, velocity: 2)
        #expect(motion.position(at: 0) == 0.2)
        #expect(motion.velocity(at: 0) == 2)
        let dt = 1e-7
        #expect(abs((motion.position(at: dt) - 0.2) / dt - 2) < 0.001)
    }

    @Test func noReportsMeansStoppingAtTheForecast() {
        let motion = SwipeTrajectory(start: 0.1, target: 0.4, velocity: 3)
        #expect(abs(motion.position(at: motion.duration) - 0.4) < 1e-9)
        #expect(motion.velocity(at: motion.duration) == 0)
        #expect(motion.position(at: 10) == motion.position(at: motion.duration))
        #expect(motion.velocity(at: 10) == 0)
    }

    @Test func retargetingPreservesPositionAndOrdinaryVelocity() {
        let old = SwipeTrajectory(start: 0, target: 0.3, velocity: 1)
        let elapsed = 0.02
        let new = SwipeTrajectory(start: old.position(at: elapsed), target: 0.5, velocity: old.velocity(at: elapsed))
        #expect(new.position(at: 0) == old.position(at: elapsed))
        #expect(new.velocity(at: 0) == old.velocity(at: elapsed))
    }

    @Test func reversingTurnsAroundWithoutPositionDiscontinuity() {
        let motion = SwipeTrajectory(start: 0.2, target: 0.1, velocity: 1)
        #expect(motion.velocity(at: 0) == 1)
        #expect(motion.position(at: 0.001) > 0.2)
        #expect(motion.velocity(at: 0.03) < 0)
        #expect(abs(motion.position(at: 0.06) - 0.1) < 1e-9)
    }

    @Test func forwardTrajectoriesStayBoundedInBothDirections() {
        for sign in [-1.0, 1.0] {
            for speed in [0.0, 1, 5, 100] {
                let motion = SwipeTrajectory(start: 0, target: sign * 0.2, velocity: sign * speed)
                var previous = 0.0
                for tick in 0...60 {
                    let position = sign * motion.position(at: Double(tick) / 1000)
                    #expect(position >= previous - 1e-9 && position <= 0.2 + 1e-9)
                    previous = position
                }
            }
        }
    }

    @Test func releaseSamplesActualTrajectoryInsteadOfItsDestination() {
        let motion = SwipeTrajectory(start: 0, target: 0.5, velocity: 0)
        let releaseTime = 0.02
        #expect(motion.position(at: releaseTime) > 0)
        #expect(motion.position(at: releaseTime) < 0.5)
        #expect(motion.velocity(at: releaseTime) > 0)
    }
}
