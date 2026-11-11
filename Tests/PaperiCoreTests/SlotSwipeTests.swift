import Testing
@testable import PaperiCore

struct SlotSwipeTests {
    @Test func rubberBandResistanceIsContinuousAndBounded() {
        #expect(SlotSwipe.rubberBand(0) == 0)
        #expect(SlotSwipe.rubberBand(0.5) == 0.5)
        #expect(SlotSwipe.rubberBand(1.0) == 1.0)
        #expect(SlotSwipe.rubberBand(-0.5) == -0.5)
        #expect(SlotSwipe.rubberBand(-1.0) == -1.0)

        let beyond1 = SlotSwipe.rubberBand(1.5)
        let beyond2 = SlotSwipe.rubberBand(2.0)
        #expect(beyond1 > 1.0 && beyond1 < 1.5)
        #expect(beyond2 > beyond1 && beyond2 < 1.3)

        let negBeyond1 = SlotSwipe.rubberBand(-1.5)
        #expect(negBeyond1 == -beyond1)
    }

    @Test func verticalDominanceCancelsGesture() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.02))
        swipe.begin(at: 0.0)
        let action = swipe.move(dx: 0.005, dy: 0.025, at: 0.01)
        #expect(action == .cancelled)
        #expect(swipe.state == .cancelled)
    }

    @Test func smallMovementRemainsDetecting() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.02))
        swipe.begin(at: 0.0)
        let action = swipe.move(dx: 0.005, dy: 0.001, at: 0.01)
        #expect(action == nil)
        if case .detecting(let accX, let accY, _) = swipe.state {
            #expect(accX == 0.005 && accY == 0.001)
        } else {
            Issue.record("Expected detecting state")
        }
    }

    @Test func horizontalDominanceLocksAndStarts() {
        var swipe = SlotSwipe(config: .init(travel: 0.2, lockThreshold: 0.02))
        swipe.begin(at: 0.0)
        // dx < 0 means moving finger left -> right neighbour comes in (positive progress)
        let action = swipe.move(dx: -0.025, dy: 0.002, at: 0.01)
        #expect(action == .started)
        if case .active(let raw, let clamped, _, _) = swipe.state {
            #expect(raw > 0)
            #expect(clamped > 0)
            #expect(abs(raw - (0.025 / 0.2)) < 0.001)
        } else {
            Issue.record("Expected active state")
        }
    }

    @Test func invertConfigurationReversesSign() {
        var normal = SlotSwipe(config: .init(travel: 0.2, lockThreshold: 0.01, invert: false))
        var inverted = SlotSwipe(config: .init(travel: 0.2, lockThreshold: 0.01, invert: true))
        normal.begin(at: 0.0)
        inverted.begin(at: 0.0)
        _ = normal.move(dx: -0.05, dy: 0, at: 0.01)
        _ = inverted.move(dx: -0.05, dy: 0, at: 0.01)
        if case .active(let rawN, _, _, _) = normal.state,
           case .active(let rawI, _, _, _) = inverted.state {
            #expect(rawN > 0)
            #expect(rawI < 0)
            #expect(rawN == -rawI)
        } else {
            Issue.record("Expected active states")
        }
    }

    @Test func midGestureReversalCrossesZero() {
        var swipe = SlotSwipe(config: .init(travel: 0.1, lockThreshold: 0.01))
        swipe.begin(at: 0.0)
        _ = swipe.move(dx: -0.03, dy: 0, at: 0.01) // progress +0.3
        _ = swipe.move(dx: -0.03, dy: 0, at: 0.02) // progress +0.6
        if case .active(let p1, _, _, _) = swipe.state { #expect(p1 > 0.5) }

        // Reverse: move finger right
        _ = swipe.move(dx: 0.06, dy: 0, at: 0.03) // progress ~ 0.0
        _ = swipe.move(dx: 0.05, dy: 0, at: 0.04) // progress ~ -0.5
        if case .active(let p2, _, _, _) = swipe.state { #expect(p2 < -0.4) }
    }

    @Test func commitDecisionOnThreshold() {
        var swipe = SlotSwipe(config: .init(travel: 0.1, commitThreshold: 0.5, flickVelocity: 10.0, lockThreshold: 0.01))
        swipe.begin(at: 0.0)
        _ = swipe.move(dx: -0.06, dy: 0, at: 0.05) // progress = 0.6 >= 0.5
        let decision = swipe.end(at: 0.1)
        #expect(decision == .commit(.right))

        var swipeLeft = SlotSwipe(config: .init(travel: 0.1, commitThreshold: 0.5, flickVelocity: 10.0, lockThreshold: 0.01))
        swipeLeft.begin(at: 0.0)
        _ = swipeLeft.move(dx: 0.06, dy: 0, at: 0.05) // progress = -0.6
        let decisionLeft = swipeLeft.end(at: 0.1)
        #expect(decisionLeft == .commit(.left))
    }

    @Test func snapBackDecisionBelowThreshold() {
        var swipe = SlotSwipe(config: .init(travel: 0.1, commitThreshold: 0.5, flickVelocity: 10.0, lockThreshold: 0.01))
        swipe.begin(at: 0.0)
        _ = swipe.move(dx: -0.03, dy: 0, at: 0.05) // progress = 0.3 < 0.5
        let decision = swipe.end(at: 0.1)
        #expect(decision == .snapBack)
    }

    @Test func flickCommitsEvenBelowDistanceThreshold() {
        var swipe = SlotSwipe(config: .init(travel: 0.2, commitThreshold: 0.5, flickVelocity: 1.5, lockThreshold: 0.01))
        swipe.begin(at: 0.0)
        // Move small distance (0.04 -> progress 0.2 < 0.5), but very fast (10 ms)
        _ = swipe.move(dx: -0.04, dy: 0, at: 0.01)
        let decision = swipe.end(at: 0.01)
        #expect(decision == .commit(.right))
    }
    @Test func holdBeforeReleaseExpiresFlickVelocity() {
        var swipe = SlotSwipe()
        swipe.begin(at: 0)
        _ = swipe.move(dx: -0.04, dy: 0, at: 0.01)
        #expect(swipe.end(at: 1) == .snapBack)
    }

    @Test func holdBeforeReleasePreservesDistanceCommit() {
        var swipe = SlotSwipe()
        swipe.begin(at: 0)
        _ = swipe.move(dx: -0.24, dy: 0, at: 0.01)
        #expect(swipe.end(at: 1) == .commit(.right))
    }

    @Test func reversalFlickReturnsInsteadOfSelectingOppositeSlot() {
        for sign in [-1.0, 1.0] {
            var swipe = SlotSwipe()
            swipe.begin(at: 0)
            _ = swipe.move(dx: -sign * 0.05, dy: 0, at: 0.1)
            _ = swipe.move(dx: sign * 0.025, dy: 0, at: 0.11)
            #expect(swipe.end(at: 0.11) == .snapBack)
        }
    }

    @Test func tinyFastSwipeDoesNotCommit() {
        var swipe = SlotSwipe()
        swipe.begin(at: 0)
        _ = swipe.move(dx: -0.016, dy: 0, at: 0.001)
        #expect(swipe.end(at: 0.002) == .snapBack)
    }

    @Test func visualSpeedIsLimitedAndNeverOvershoots() {
        #expect(SlotSwipe.advanceVisualProgress(0, toward: 1, elapsed: 0.01) == 0.08)
        #expect(SlotSwipe.advanceVisualProgress(0, toward: -1, elapsed: 0.01) == -0.08)
        #expect(SlotSwipe.advanceVisualProgress(0.49, toward: 0.5, elapsed: 0.01) == 0.5)
        #expect(SlotSwipe.advanceVisualProgress(0, toward: 1, elapsed: 1) < 0.27)
        #expect(SlotSwipe.advanceVisualProgress(0.5, toward: 0, elapsed: 0) == 0.5)
    }

    @Test func settlingHasTimeToAnimateAndIsBounded() {
        #expect(SlotSwipe.settleDuration(distance: 0, base: 0.22) == 0)
        #expect(SlotSwipe.settleDuration(distance: 0.01, base: 0.22) == 0.16)
        #expect(SlotSwipe.settleDuration(distance: 1.3, base: 0.22) == 0.325)
        #expect(SlotSwipe.settleDuration(distance: 2, base: 2) == 0.5)
    }

    @Test func ambiguousDiagonalCanResolveHorizontally() {
        var swipe = SlotSwipe()
        swipe.begin(at: 0)
        #expect(swipe.move(dx: -0.016, dy: 0.015, at: 0.01) == nil)
        #expect(swipe.move(dx: -0.02, dy: 0.001, at: 0.02) == .started)
        #expect(swipe.move(dx: -0.01, dy: 0, at: 0.03) != nil)
    }


    @Test func upwardSwipeTracksCloseWhenEnabled() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.01, closeTravel: 0.2))
        swipe.begin(at: 0.0)
        #expect(swipe.move(dx: 0.001, dy: 0.02, at: 0.01) == .closeStarted)
        // Raw 0.1 at the lock, 0.6 now; shown progress starts at the lock
        // and meets raw at 1: (0.6 - 0.1) / 0.9.
        let action = swipe.move(dx: 0, dy: 0.1, at: 0.05)
        guard case .closeUpdated(let shown) = action else { Issue.record("Expected update"); return }
        #expect(abs(shown - 0.5 / 0.9) < 1e-9)
        #expect(swipe.end(at: 0.06) == .close)
    }

    @Test func downwardSwipeCancelsEvenWithCloseEnabled() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.01, closeTravel: 0.2))
        swipe.begin(at: 0.0)
        #expect(swipe.move(dx: 0, dy: -0.02, at: 0.01) == .cancelled)
    }

    @Test func shortOrReturnedCloseSnapsBack() {
        var short = SlotSwipe(config: .init(lockThreshold: 0.01, closeTravel: 0.2))
        short.begin(at: 0.0)
        _ = short.move(dx: 0, dy: 0.02, at: 0.01)
        _ = short.move(dx: 0, dy: 0.01, at: 0.2)
        #expect(short.end(at: 0.5) == .snapBack)

        var back = SlotSwipe(config: .init(lockThreshold: 0.01, closeTravel: 0.2))
        back.begin(at: 0.0)
        _ = back.move(dx: 0, dy: 0.15, at: 0.05)
        // Dragged below the start: progress stays at zero, release is no close.
        #expect(back.move(dx: 0, dy: -0.25, at: 0.3) == .closeUpdated(progress: 0))
        #expect(back.end(at: 0.6) == .snapBack)
    }

    @Test func closeLockStartsFromRest() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.015, closeTravel: 0.4))
        swipe.begin(at: 0.0)
        #expect(swipe.move(dx: 0, dy: 0.02, at: 0.02) == .closeStarted)
        if case .closing(let raw, let clamped, let velocity, _) = swipe.state {
            #expect(abs(raw - 0.05) < 1e-9 && clamped == 0)
            #expect(velocity > 0)
        } else { Issue.record("Expected closing state") }
    }

    @Test func followVisualProgressEasesWithoutOvershoot() {
        // One 120 Hz frame covers part of the gap, never all of it or beyond.
        let first = SlotSwipe.followVisualProgress(0, toward: 0.04, elapsed: 1.0 / 120)
        #expect(first > 0.01 && first < 0.04)
        var p = 0.0
        for _ in 0..<60 { p = SlotSwipe.followVisualProgress(p, toward: 0.5, elapsed: 1.0 / 120) }
        #expect(p == 0.5)
        // The speed limit still holds for a large jump.
        #expect(SlotSwipe.followVisualProgress(0, toward: 5, elapsed: 1.0 / 60) <= SlotSwipe.maximumVisualSpeed / 60 + 1e-9)
    }

    @Test func settleMatchesReleaseSpeed() {
        // Slow release: gentle start, slope well under ease-out's 1.7.
        let slowDuration = SlotSwipe.settleDuration(distance: 0.5, speed: 0.5, base: 0.22)
        let slow = SlotSwipe.settleCurve(speed: 0.5, distance: 0.5, duration: slowDuration)
        #expect(slow.1 / slow.0 < 1.0)
        // Fast release: shorter, and the curve starts steep to keep the speed.
        let fastDuration = SlotSwipe.settleDuration(distance: 0.5, speed: 6, base: 0.22)
        #expect(fastDuration < slowDuration)
        let fast = SlotSwipe.settleCurve(speed: 6, distance: 0.5, duration: fastDuration)
        #expect(abs(fast.1 / fast.0 - 6 * fastDuration / 0.5) < 1e-9)
        // Moving the other way (or not at all) starts from rest.
        #expect(SlotSwipe.settleCurve(speed: -2, distance: 0.5, duration: 0.2).1 == 0)
    }

    @Test func fastUpwardFlickCloses() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.01, closeTravel: 0.4))
        swipe.begin(at: 0.0)
        _ = swipe.move(dx: 0, dy: 0.02, at: 0.01)
        _ = swipe.move(dx: 0, dy: 0.04, at: 0.03)
        #expect(swipe.end(at: 0.035) == .close)
    }
}
