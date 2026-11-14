import AppKit
import Testing
@testable import PaperiPlatform

@MainActor
struct TouchSourceTests {
    private func contacts(_ ids: [Int], x: Double = 0, phase: NSTouch.Phase = .moved) -> [EventTapTouchSource.Contact] {
        ids.map { .init(id: AnyHashable($0), position: CGPoint(x: x, y: 0), phase: phase) }
    }

    @Test func briefDropoutResumesWithNewIdentitiesWithoutJump() {
        let source = EventTapTouchSource()
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1, 2, 3]), at: 1)
        source.processContacts(contacts([1]), at: 1.01)
        source.processContacts(contacts([1, 4, 5], x: 0.5), at: 1.04)
        #expect(events == [.begin(time: 1)])
        source.processContacts(contacts([1, 4, 5], x: 0.75), at: 1.05)
        #expect(events.last == .move(dx: 0.25, dy: 0, time: 1.05))
        source.stop()
    }

    @Test func addedPalmDoesNotMoveCancelOrHoldOpenEstablishedSwipe() {
        let source = EventTapTouchSource()
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1, 2, 3]), at: 1)
        source.processContacts(contacts([1, 2, 3], x: 0.1), at: 1.01)
        source.processContacts(contacts([1, 2, 3], x: 0.2) + contacts([4], x: 0.9, phase: .began), at: 1.02)
        #expect(events.count == 3)
        if case .move(let dx, _, _) = events.last { #expect(abs(dx - 0.1) < 0.000001) }
        else { Issue.record("Expected movement from original fingers") }
        source.processContacts(contacts([1, 2, 3], x: 0.3) + contacts([4], phase: .cancelled), at: 1.03)
        #expect(events.count == 4)
        source.processContacts(contacts([1, 2, 3], phase: .ended) + contacts([4]), at: 1.04)
        source.finishPendingRelease(at: 1.11)
        #expect(events.last == .end(time: 1.04))
        source.stop()
    }

    @Test func sustainedLossEndsAtOriginalLiftTime() {
        let source = EventTapTouchSource()
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1, 2, 3]), at: 1)
        source.processContacts(contacts([1, 2]), at: 1.01)
        source.processContacts(contacts([1]), at: 1.04)
        source.finishPendingRelease(at: 1.08)
        #expect(events == [.begin(time: 1), .end(time: 1.01)])
        source.stop()
    }

    @Test func fullLiftFinishesWithoutFurtherFrames() async throws {
        let source = EventTapTouchSource()
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1, 2, 3]), at: 1)
        source.processContacts(contacts([1, 2, 3], phase: .ended), at: 1.01)
        try await Task.sleep(for: .milliseconds(150))
        #expect(events == [.begin(time: 1), .end(time: 1.01)])
        source.stop()
    }

    @Test func cancellationAndExtraFingersCancelImmediately() {
        for frame in [contacts([1], phase: .cancelled), contacts([1, 2, 3, 4])] {
            let source = EventTapTouchSource()
            var events: [TouchEvent] = []
            source.onEvent = { events.append($0) }
            source.processContacts(contacts([1, 2, 3]), at: 1)
            source.processContacts(contacts([1, 2]), at: 1.01)
            source.processContacts(frame, at: 1.02)
            source.finishPendingRelease(at: 2)
            #expect(events == [.begin(time: 1), .cancel])
            source.stop()
        }
    }

    @Test func emptyFramesDoNotReleaseAndStopCancelsTimer() {
        let source = EventTapTouchSource()
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1, 2, 3]), at: 1)
        source.processContacts([], at: 1.01)
        #expect(events == [.begin(time: 1)])
        source.processContacts(contacts([1]), at: 1.02)
        source.stop()
        source.finishPendingRelease(at: 2)
        #expect(events == [.begin(time: 1), .cancel])
    }

    @Test func scrollJoinedByAnotherHandDoesNotStartSwipe() {
        let source = EventTapTouchSource()
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        // Two-finger scroll, then a finger of the other hand lands.
        for i in 0..<10 { source.processContacts(contacts([1, 2], x: Double(i) * 0.01), at: 1 + Double(i) * 0.05) }
        source.processContacts(contacts([1, 2], x: 0.1) + contacts([9], x: 0.9, phase: .began), at: 1.5)
        source.processContacts(contacts([1, 2, 9], x: 0.3), at: 1.55)
        // Lifting the scroll fingers and landing them again does not reset it.
        source.processContacts(contacts([9]), at: 1.6)
        source.processContacts(contacts([3, 4, 9]), at: 1.65)
        #expect(events.isEmpty)
        // After every finger lifts, a real swipe starts as usual.
        source.processContacts(contacts([3, 4, 9], phase: .ended), at: 1.7)
        source.processContacts(contacts([5], phase: .began), at: 2)
        source.processContacts(contacts([5, 6, 7], phase: .began), at: 2.06)
        #expect(events == [.begin(time: 2.06)])
        source.stop()
    }

    @Test func missedLiftDoesNotBlockNextSwipe() {
        let source = EventTapTouchSource()
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1, 2]), at: 1)
        // Contacts 1 and 2 vanish without an ended frame.
        source.processContacts(contacts([3, 4, 5]), at: 5)
        #expect(events == [.begin(time: 5)])
        source.stop()
    }

    @Test func tapEndsSequenceAtOnceThenReportsTap() {
        let source = EventTapTouchSource()
        source.recognizesTaps = true
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1], x: 0.3), at: 1, clicked: false)
        source.processContacts(contacts([1, 2, 3], x: 0.3), at: 1.02, clicked: false)
        source.processContacts(contacts([1, 2, 3], x: 0.3, phase: .ended), at: 1.1, clicked: false)
        #expect(events == [.begin(time: 1.02), .end(time: 1.1), .tap(time: 1.1)])
        source.stop()
    }

    @Test func swipeIsNotATapAndTapsCanBeOff() {
        for recognizes in [true, false] {
            let source = EventTapTouchSource()
            source.recognizesTaps = recognizes
            var events: [TouchEvent] = []
            source.onEvent = { events.append($0) }
            let x = recognizes ? 0.2 : 0
            source.processContacts(contacts([1, 2, 3]), at: 1, clicked: false)
            source.processContacts(contacts([1, 2, 3], x: x), at: 1.05, clicked: false)
            source.processContacts(contacts([1, 2, 3], x: x, phase: .ended), at: 1.1, clicked: false)
            source.finishPendingRelease(at: 1.2)
            #expect(!events.contains(.tap(time: 1.1)))
            #expect(events.last == .end(time: 1.1))
            source.stop()
        }
    }

    @Test func clickIsNotATap() {
        let source = EventTapTouchSource()
        source.recognizesTaps = true
        var events: [TouchEvent] = []
        source.onEvent = { events.append($0) }
        source.processContacts(contacts([1, 2, 3]), at: 1, clicked: true)
        source.processContacts(contacts([1, 2, 3], phase: .ended), at: 1.1, clicked: false)
        source.finishPendingRelease(at: 1.2)
        #expect(events == [.begin(time: 1), .end(time: 1.1)])
        source.stop()
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

    @Test func swipeBlocksPhasedScrollWithoutContinuousFlag() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 3))
        #expect(drop(&f, .scroll(phase: began, momentum: 0, continuous: false)))
        #expect(drop(&f, .scroll(phase: changed, momentum: 0, continuous: false)))
        #expect(!drop(&f, .scroll(phase: 0, momentum: 0, continuous: false)))
    }

    @Test func swipeBlocksScrollTailAfterFingersLift() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 3))
        #expect(drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        _ = drop(&f, .fingers(down: 0))
        #expect(drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        #expect(drop(&f, .scroll(phase: ended, momentum: 0, continuous: true)))
        #expect(drop(&f, .scroll(phase: 0, momentum: 1, continuous: true)))
        #expect(drop(&f, .scroll(phase: 0, momentum: AppGestureFilter.momentumEnd, continuous: true)))
        _ = drop(&f, .fingers(down: 2))
        #expect(!drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        #expect(!drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
    }

    @Test func lateScrollBeginsAndUpdatesStayBlockedUntilNewContact() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 3))
        _ = drop(&f, .fingers(down: 0))
        for phase in [AppGestureFilter.phaseMayBegin, began, changed, ended] {
            #expect(drop(&f, .scroll(phase: phase, momentum: 0, continuous: true)))
        }
        #expect(drop(&f, .scroll(phase: 0, momentum: 1, continuous: true)))
        #expect(drop(&f, .scroll(phase: 0, momentum: AppGestureFilter.momentumEnd, continuous: true)))
        #expect(drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        _ = drop(&f, .fingers(down: 2))
        #expect(!drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        #expect(!drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
    }

    @Test func discreteSwipeAfterLiftStaysBlockedUntilNewContact() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 3))
        _ = drop(&f, .fingers(down: 0))
        #expect(drop(&f, .gesture))
        _ = drop(&f, .fingers(down: 0))
        #expect(drop(&f, .gesture))
        _ = drop(&f, .fingers(down: 2))
        #expect(!drop(&f, .gesture))
    }

    @Test func slowlyJoinedFingersLeaveScrollToApp() {
        var f = AppGestureFilter(fingers: 3)
        _ = f.shouldDrop(.fingers(down: 2, landingSpread: 0.01))
        #expect(!drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        _ = f.shouldDrop(.fingers(down: 3, landingSpread: 0.8))
        #expect(!f.claimed)
        #expect(!drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        // Still the app's after a scroll finger lifts and lands again.
        _ = f.shouldDrop(.fingers(down: 2, landingSpread: 0.8))
        _ = f.shouldDrop(.fingers(down: 3, landingSpread: 0.9))
        #expect(!f.claimed)
        _ = f.shouldDrop(.fingers(down: 0))
        _ = f.shouldDrop(.fingers(down: 3, landingSpread: 0.03))
        #expect(f.claimed)
    }

    @Test func claimLastsUntilEveryFingerLifts() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 3))
        _ = drop(&f, .fingers(down: 2))
        #expect(drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
        #expect(f.claimed)
        _ = drop(&f, .fingers(down: 0))
        #expect(!f.claimed)
        #expect(drop(&f, .scroll(phase: began, momentum: 0, continuous: true)))
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
        #expect(drop(&f, .scroll(phase: 0, momentum: 1, continuous: true)))
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

    @Test func fourFingerSystemGesturesPassThrough() {
        var f = AppGestureFilter(fingers: 3)
        // Fingers land a few ms apart: 3 is passed through on the way to 4.
        _ = drop(&f, .fingers(down: 3))
        _ = drop(&f, .fingers(down: 4))
        #expect(!f.claimed)
        #expect(!drop(&f, .touchFrame))
        #expect(!drop(&f, .gesture))
        #expect(!drop(&f, .gestureBegin))
        // Lifting back down through 3 fingers does not claim the sequence.
        _ = drop(&f, .fingers(down: 3))
        #expect(!drop(&f, .touchFrame))
        #expect(!drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        _ = drop(&f, .fingers(down: 0))
        // The next three-finger swipe is claimed again.
        _ = drop(&f, .fingers(down: 3))
        #expect(drop(&f, .touchFrame))
    }

    @Test func establishedSwipeKeepsClaimWhenPalmAppears() {
        var f = AppGestureFilter(fingers: 3)
        _ = drop(&f, .fingers(down: 3))
        f.swipeEstablished = true
        _ = drop(&f, .fingers(down: 4))
        #expect(f.claimed)
        #expect(drop(&f, .touchFrame))
        #expect(drop(&f, .scroll(phase: changed, momentum: 0, continuous: true)))
        _ = drop(&f, .fingers(down: 0))
        #expect(!f.claimed)
    }

    @Test func fiveFingerPinchPassesThrough() {
        var f = AppGestureFilter(fingers: 3)
        for n in [1, 3, 5] { _ = drop(&f, .fingers(down: n)) }
        #expect(!drop(&f, .gesture))
    }

    @Test func fourFingerSwipeConfigIgnoresThreeFingers() {
        var f = AppGestureFilter(fingers: 4)
        _ = drop(&f, .fingers(down: 3))
        #expect(!drop(&f, .touchFrame))
        _ = drop(&f, .fingers(down: 4))
        #expect(drop(&f, .touchFrame))
    }
}

struct FingerCountValidationTests {
    @Test func transientDisagreementRecovers() {
        var validation = FingerCountValidation()
        validation.observe(appKit: 2, device: 3, at: 0)
        validation.observe(appKit: 3, device: 3, at: 0.02)
        validation.observe(appKit: 2, device: 3, at: 1)
        #expect(!validation.failed)
    }

    @Test func sustainedDisagreementRequiresSustainedActiveAgreement() {
        var validation = FingerCountValidation()
        for time in [0.0, 0.05, 0.10, 0.16] {
            validation.observe(appKit: 2, device: 3, at: time)
        }
        #expect(validation.failed)
        validation.observe(appKit: 2, device: 2, at: 1)
        #expect(validation.failed)
        for time in [1.05, 1.10, 1.16] {
            validation.observe(appKit: 2, device: 2, at: time)
        }
        #expect(!validation.failed)
    }

    @Test func separateActionsDoNotAccumulateMismatch() {
        var validation = FingerCountValidation()
        for time in [0.0, 1.0, 2.0, 3.0] {
            validation.observe(appKit: 2, device: 3, at: time)
        }
        #expect(!validation.failed)
    }

    @Test func idleAgreementDoesNotRestoreUnsafeCounts() {
        var validation = FingerCountValidation()
        for time in [0.0, 0.05, 0.10, 0.16] {
            validation.observe(appKit: 2, device: 3, at: time)
        }
        for time in [0.2, 0.3, 0.4, 0.5] {
            validation.observe(appKit: 0, device: 0, at: time)
        }
        #expect(validation.failed)
    }
}
