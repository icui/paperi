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
    @Test func swipeUpWindowMovementUsesTrajectories() {
        var state = LiveManager.Swipe(
            space: 1, generation: 1, overlay: SnapshotTransition(), surveys: [:],
            ends: [:], neighbours: [:], canvas: Rect(x: 0, y: 0, width: 1000, height: 800),
            closeWindow: 1, tabClose: nil)
        #expect(state.usesTrajectoryTracking)
        state.closing = true
        #expect(state.usesTrajectoryTracking)
        state.pulling = true
        #expect(!state.usesTrajectoryTracking)
        let tab = LiveManager.Swipe(
            space: 1, generation: 1, overlay: SnapshotTransition(), surveys: [:],
            ends: [:], neighbours: [:], canvas: Rect(x: 0, y: 0, width: 1000, height: 800),
            closeWindow: 1, tabClose: .native)
        var tabUp = tab
        tabUp.closing = true
        #expect(tabUp.showsIndicator)
        #expect(!tabUp.usesTrajectoryTracking)
    }

    @Test func swipeUpCannotMoveBelowRestDuringReversal() {
        var state = LiveManager.Swipe(
            space: 1, generation: 1, overlay: SnapshotTransition(), surveys: [:],
            ends: [:], neighbours: [:], canvas: Rect(x: 0, y: 0, width: 1000, height: 800),
            closeWindow: 1, tabClose: nil)
        state.closing = true
        let motion = SwipeTrajectory(start: 0.001, target: 0.1, velocity: -5)
        state.trackingMotion = motion
        state.trackingBegan = 10
        #expect(motion.position(at: 0.001) < 0)
        state.sampleTracking(at: 10.001)
        #expect(state.progress == 0)
        #expect(state.visualVelocity == 0)
        state.sampleTracking(at: 10.03)
        #expect(state.progress > 0)
    }
}
