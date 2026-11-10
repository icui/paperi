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

struct AppGestureFilterTests {
    private let began = AppGestureFilter.phaseBegan
    private let changed = AppGestureFilter.phaseChanged
    private let ended = AppGestureFilter.phaseEnded

    private func drop(_ f: inout AppGestureFilter, _ input: AppGestureFilter.Input) -> Bool {
        f.shouldDrop(input)
    }

    @Test func twoFingerScrollPassesThrough() {
        var f = AppGestureFilter(fingers: 3)
        #expect(!drop(&f, .fingers(down: 2)))
        #expect(!drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        #expect(!drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        #expect(!drop(&f, .gesture))
    }

    @Test func swipeFingersBlockScrollAndGestures() {
        var f = AppGestureFilter(fingers: 3)
        _ = f.shouldDrop(.fingers(down: 3))
        #expect(drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        #expect(drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        #expect(drop(&f, .scroll(phase: ended, momentum: 0, continuous: true)))
        #expect(drop(&f, .gesture))
        #expect(!drop(&f, .scroll(phase: 0, momentum: 0, continuous: false)))
    }

    @Test func claimLastsUntilEveryFingerLifts() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 3))
        _ = drop(&f, .fingers(down: 2))
        #expect(drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        #expect(f.claimed)
        _ = drop(&f, .fingers(down: 0))
        #expect(!f.claimed)
        #expect(!drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
    }

    @Test func openAppScrollClosesAndItsMomentumIsSwallowed() {
        var f = AppGestureFilter(fingers: 3)
        _ = f.shouldDrop(.fingers(down: 2))
        #expect(!drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        _ = f.shouldDrop(.fingers(down: 3))
        #expect(drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        #expect(!drop(&f, .scroll(phase: ended, momentum: 0, continuous: true)))
        _ = f.shouldDrop(.fingers(down: 0))
        #expect(drop(&f, .scroll(phase: 0, momentum: 1, continuous: true)))
        #expect(drop(&f, .scroll(phase: 0, momentum: AppGestureFilter.momentumEnd, continuous: true)))
        #expect(!drop(&f, .scroll(phase: 0, momentum: 1, continuous: true)))
    }

    @Test func swipeTouchFramesAreWithheldUntilAllFingersLift() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 2))
        #expect(!drop(&f, .touchFrame))
        _ = drop(&f, .fingers(down: 3))
        #expect(drop(&f, .touchFrame))
        _ = drop(&f, .fingers(down: 1))
        #expect(drop(&f, .touchFrame))
        _ = drop(&f, .fingers(down: 0))
        #expect(!drop(&f, .touchFrame))
        #expect(!drop(&f, .fingers(down: 3)))
    }

    @Test func gestureBracketsStayBalanced() {
        var f = AppGestureFilter(fingers: 3)
        // Began before the claim: its end is delivered.
        #expect(!drop(&f, .gestureBegin))
        _ = drop(&f, .fingers(down: 3))
        #expect(!drop(&f, .gestureEnd))
        // Begun during the claim: both withheld.
        #expect(drop(&f, .gestureBegin))
        #expect(drop(&f, .gestureEnd))
        _ = drop(&f, .fingers(down: 0))
        #expect(!drop(&f, .gestureBegin))
    }
}
