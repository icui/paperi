import AppKit
import Testing
@testable import PaperiPlatform

@MainActor
struct TouchSourceTests {
    @Test func cancellationTakesPriorityOverRelease() {
        #expect(EventTapTouchSource.termination(phases: [.cancelled, .ended, .stationary], fingers: 3, at: 1) == .cancel)
        #expect(EventTapTouchSource.termination(phases: [.cancelled], fingers: 3, at: 1) == .cancel)
    }

    @Test func emptyGestureEventsDoNotReleaseFingers() {
        #expect(EventTapTouchSource.termination(phases: [], fingers: 3, at: 1) == nil)
    }

    @Test func ordinaryReleaseEndsAndMovementContinues() {
        #expect(EventTapTouchSource.termination(phases: [.ended, .stationary, .stationary], fingers: 3, at: 1) == .end(time: 1))
        #expect(EventTapTouchSource.termination(phases: [.stationary, .stationary], fingers: 3, at: 1) == .end(time: 1))
        #expect(EventTapTouchSource.termination(phases: [.moved, .stationary, .stationary], fingers: 3, at: 1) == nil)
    }
}
