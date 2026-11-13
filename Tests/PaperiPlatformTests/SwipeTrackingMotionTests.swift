import Testing
import PaperiCore
@testable import PaperiPlatform

@MainActor
struct SwipeTrackingMotionTests {
    @Test func trackingAndReleaseReadTheInFlightMotion() {
        var state = LiveManager.Swipe(
            space: 1, generation: 1, overlay: SnapshotTransition(), surveys: [:],
            ends: [:], neighbours: [:], canvas: Rect(x: 0, y: 0, width: 1000, height: 800),
            closeWindow: nil, tabClose: nil)
        let motion = SwipeTrajectory(start: 0.1, target: 0.5, velocity: 1)
        state.trackingMotion = motion
        state.trackingBegan = 10
        state.sampleTracking(at: 10.02)
        #expect(abs(state.progress - motion.position(at: 0.02)) < 1e-9)
        #expect(abs(state.visualVelocity - motion.velocity(at: 0.02)) < 1e-9)
        #expect(state.progress < motion.target)
        state.sampleTracking(at: 11)
        #expect(abs(state.progress - motion.target) < 1e-9)
        #expect(state.visualVelocity == 0)
    }
}
