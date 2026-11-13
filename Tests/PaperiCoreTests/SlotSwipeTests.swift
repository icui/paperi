import Testing
@testable import PaperiCore

struct SlotSwipeTests {
    @Test func pullTurnsLeftAndCommits() {
        var swipe = SlotSwipe(config: .init(pullTravel: 0.4, turnTravel: 0.4))
        swipe.begin(at: 0)
        #expect(swipe.move(dx: 0, dy: -0.04, at: 0.01) == .pullStarted)
        #expect(swipe.move(dx: -0.07, dy: 0, at: 0.02) == .turnStarted)
        #expect(swipe.turnDirection == .left)
        _ = swipe.move(dx: -0.24, dy: 0, at: 0.2)
        #expect(swipe.end(at: 0.21) == .turn)
    }

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
            // Shown progress starts from rest at the lock.
            #expect(clamped == 0)
            #expect(abs(raw - (0.025 / 0.2)) < 0.001)
        } else {
            Issue.record("Expected active state")
        }
    }

    @Test func shownProgressMeetsRawAtBothNeighbours() {
        for origin in [0.0375, -0.0375] {
            #expect(SlotSwipe.shown(origin, origin: origin) == 0)
            #expect(abs(SlotSwipe.shown(1, origin: origin) - 1) < 1e-12)
            #expect(abs(SlotSwipe.shown(-1, origin: origin) + 1) < 1e-12)
            #expect(SlotSwipe.shown(1.2, origin: origin) == 1.2)
            // Monotonic and continuous through the start.
            var previous = -Double.infinity
            for step in -120...120 {
                let value = SlotSwipe.shown(Double(step) / 100, origin: origin)
                #expect(value > previous)
                if previous.isFinite { #expect(value - previous < 0.02) }
                previous = value
            }
        }
    }

    @Test func reversalPastStartShowsTheOtherNeighbour() {
        var swipe = SlotSwipe(config: .init(travel: 0.2, lockThreshold: 0.01))
        swipe.begin(at: 0)
        #expect(swipe.move(dx: -0.012, dy: 0, at: 0.01) == .started) // right, raw 0.06
        // Back past the start: shown goes negative (left neighbour) and
        // reaches -1 exactly where raw does.
        guard case .updated(let back) = swipe.move(dx: 0.05, dy: 0, at: 0.05) else { Issue.record("update"); return }
        #expect(back < 0)
        guard case .updated(let full) = swipe.move(dx: 0.162, dy: 0, at: 0.1) else { Issue.record("update"); return }
        #expect(abs(full + 1) < 1e-9)
        #expect(swipe.end(at: 0.2) == .commit(.left))
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

    @Test func downwardSwipeTracksPullWhenEnabled() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.01, closeTravel: 0.2, pullTravel: 0.2))
        swipe.begin(at: 0.0)
        #expect(swipe.move(dx: 0.001, dy: -0.02, at: 0.01) == .pullStarted)
        guard case .pullUpdated(let shown) = swipe.move(dx: 0, dy: -0.1, at: 0.05) else { Issue.record("update"); return }
        #expect(abs(shown - 0.5 / 0.9) < 1e-9)
        #expect(swipe.end(at: 0.06) == .pull)
    }

    @Test func pullDraggedBackUpSnapsBack() {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.01, pullTravel: 0.2))
        swipe.begin(at: 0.0)
        _ = swipe.move(dx: 0, dy: -0.15, at: 0.05)
        #expect(swipe.move(dx: 0, dy: 0.25, at: 0.3) == .pullUpdated(progress: 0))
        #expect(swipe.end(at: 0.6) == .snapBack)
        // Upwards without closeTravel still cancels.
        var up = SlotSwipe(config: .init(lockThreshold: 0.01, pullTravel: 0.2))
        up.begin(at: 0)
        #expect(up.move(dx: 0, dy: 0.02, at: 0.01) == .cancelled)
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

    // Down past the commit threshold, then right: a turn.
    private func armedPull() -> SlotSwipe {
        var swipe = SlotSwipe(config: .init(lockThreshold: 0.01, pullTravel: 0.2, turnTravel: 0.2))
        swipe.begin(at: 0)
        _ = swipe.move(dx: 0, dy: -0.02, at: 0.01)
        _ = swipe.move(dx: 0, dy: -0.12, at: 0.1)
        return swipe
    }

    @Test func armedPullTurningRightClosesInstead() {
        var swipe = armedPull()
        // A small sideways drift does not turn yet.
        #expect(swipe.move(dx: 0.01, dy: 0, at: 0.2) != .turnStarted)
        #expect(swipe.move(dx: 0.035, dy: -0.002, at: 0.25) == .turnStarted)
        guard case .turning(_, let shown, _, _) = swipe.state else { Issue.record("turning"); return }
        #expect(shown == 0)
        guard case .turnUpdated(let progress) = swipe.move(dx: 0.12, dy: 0, at: 0.4) else { Issue.record("update"); return }
        #expect(progress > 0.5)
        #expect(swipe.end(at: 0.45) == .turn)
    }

    @Test func turnReleasedEarlyDoesNothing() {
        var swipe = armedPull()
        #expect(swipe.move(dx: 0.045, dy: 0, at: 0.2) == .turnStarted)
        _ = swipe.move(dx: 0.01, dy: 0, at: 0.5)
        // Neither the tab close nor the pull it came from.
        #expect(swipe.end(at: 0.7) == .snapBack)
    }

    @Test func earlyRightTurnCannotFallBackToNewWindow() {
        var early = SlotSwipe(config: .init(lockThreshold: 0.01, pullTravel: 0.2, turnTravel: 0.2))
        early.begin(at: 0)
        _ = early.move(dx: 0, dy: -0.02, at: 0.01)
        _ = early.move(dx: 0, dy: -0.02, at: 0.05) // shown progress well below 0.5
        #expect(early.move(dx: 0.045, dy: 0, at: 0.1) == .turnStarted)
        // Releasing a short turn must never run the original new-window action.
        #expect(early.end(at: 0.3) == .snapBack)

        var completed = SlotSwipe(config: .init(lockThreshold: 0.01, pullTravel: 0.2, turnTravel: 0.2))
        completed.begin(at: 0)
        _ = completed.move(dx: 0, dy: -0.02, at: 0.01)
        #expect(completed.move(dx: 0.045, dy: -0.002, at: 0.05) == .turnStarted)
        _ = completed.move(dx: 0.12, dy: 0, at: 0.2)
        #expect(completed.end(at: 0.4) == .turn)

        var off = SlotSwipe(config: .init(lockThreshold: 0.01, pullTravel: 0.2))
        off.begin(at: 0)
        _ = off.move(dx: 0, dy: -0.02, at: 0.01)
        _ = off.move(dx: 0, dy: -0.12, at: 0.1)
        if case .pullUpdated = off.move(dx: 0.06, dy: 0, at: 0.2) {} else { Issue.record("still pulling") }
        #expect(off.end(at: 0.3) == .pull)
    }

    @Test func diagonalWhileStillPullingDoesNotTurn() {
        var swipe = armedPull()
        // Mostly down with some rightward drift keeps pulling.
        for step in 1...6 {
            if case .pullUpdated = swipe.move(dx: 0.01, dy: -0.02, at: 0.1 + Double(step) * 0.02) {} else {
                Issue.record("still pulling"); return
            }
        }
        #expect(swipe.end(at: 0.3) == .pull)
    }

    // Default thresholds: what fingers do around the release of a plain pull.
    private func defaultArmedPull() -> SlotSwipe {
        var swipe = SlotSwipe(config: .init(pullTravel: 0.4, turnTravel: 0.4))
        swipe.begin(at: 0)
        _ = swipe.move(dx: 0, dy: -0.03, at: 0.01)
        _ = swipe.move(dx: 0, dy: -0.25, at: 0.15)
        return swipe
    }

    @Test func liftOffDriftKeepsThePull() {
        var swipe = defaultArmedPull()
        // A few percent of sideways drift as the fingers slow and lift.
        for step in 1...4 {
            if case .pullUpdated = swipe.move(dx: 0.01, dy: -0.002, at: 0.15 + Double(step) * 0.01) {} else {
                Issue.record("still pulling"); return
            }
        }
        #expect(swipe.end(at: 0.2) == .pull)
    }

    @Test func diagonalDriftDoesNotTurn() {
        var swipe = defaultArmedPull()
        // Well past the lock distance, but only 1.5x more sideways than down.
        if case .pullUpdated = swipe.move(dx: 0.075, dy: -0.05, at: 0.2) {} else { Issue.record("still pulling") }
        #expect(swipe.end(at: 0.25) == .pull)
    }

    @Test func turnLeadInAloneCannotFlickCommit() {
        var swipe = defaultArmedPull()
        // A fast sideways twitch that just locks a turn, released at once.
        #expect(swipe.move(dx: 0.065, dy: 0, at: 0.16) == .turnStarted)
        _ = swipe.move(dx: 0.01, dy: 0, at: 0.165)
        #expect(swipe.end(at: 0.17) == .snapBack)

        // A deliberate fast turn still commits on a flick.
        var flick = defaultArmedPull()
        #expect(flick.move(dx: 0.065, dy: 0, at: 0.16) == .turnStarted)
        for step in 1...4 { _ = flick.move(dx: 0.02, dy: 0, at: 0.16 + Double(step) * 0.01) }
        #expect(flick.end(at: 0.205) == .turn)
    }
}

struct SlotSwipeCatchTests {

    @Test func caughtSwipeStartsWhereTheStripWas() {
        var swipe = SlotSwipe()
        swipe.begin(at: 0)
        #expect(swipe.move(dx: -0.02, dy: 0, at: 0.01) == .started)
        swipe.anchor(offset: -0.3)
        guard case .active(_, let shown, _, _) = swipe.state else { Issue.record("active"); return }
        #expect(abs(shown + 0.3) < 1e-9)
        // Follows the fingers from there, one slot per `travel`.
        guard case .updated(let next) = swipe.move(dx: -0.08, dy: 0, at: 0.05) else { Issue.record("update"); return }
        #expect(next > -0.3 && next < 0)
    }

    @Test func quickSecondFlickStepsPastTheCaughtColumn() {
        // Caught 0.2 short of the first swipe's column, then flicked on:
        // the next column, although the strip never passed the first.
        var swipe = SlotSwipe()
        swipe.begin(at: 0)
        _ = swipe.move(dx: -0.02, dy: 0, at: 0.01)
        swipe.anchor(offset: -0.2)
        _ = swipe.move(dx: -0.04, dy: 0, at: 0.03)
        #expect(swipe.end(at: 0.035) == .commit(.right))
    }

    @Test func caughtSwipeSettlesWhereItIsLeft() {
        // Slow drag that leaves the strip near its column: settles there,
        // though the fingers travelled what would commit from rest.
        var near = SlotSwipe(config: .init(startOffset: -0.4))
        near.begin(at: 0)
        _ = near.move(dx: -0.02, dy: 0, at: 0.1)
        _ = near.move(dx: -0.2, dy: 0, at: 1)
        #expect(near.end(at: 1.5) == .snapBack)

        // Dragged back past halfway to the column it came from: goes there.
        var back = SlotSwipe(config: .init(startOffset: -0.3))
        back.begin(at: 0)
        _ = back.move(dx: 0.02, dy: 0, at: 0.1)
        _ = back.move(dx: 0.06, dy: 0, at: 1)
        #expect(back.end(at: 1.5) == .commit(.left))
    }

    @Test func reverseFlickUndoesTheLanding() {
        var swipe = SlotSwipe(config: .init(startOffset: -0.25))
        swipe.begin(at: 0)
        _ = swipe.move(dx: 0.02, dy: 0, at: 0.01)
        _ = swipe.move(dx: 0.04, dy: 0, at: 0.03)
        #expect(swipe.end(at: 0.035) == .commit(.left))
    }

    @Test func zeroOffsetKeepsThePlainRule() {
        for (dx, expected) in [(-0.24, SlotSwipe.Decision.commit(.right)), (-0.1, .snapBack), (0.24, .commit(.left))] {
            var plain = SlotSwipe()
            plain.begin(at: 0)
            _ = plain.move(dx: dx, dy: 0, at: 0.5)
            #expect(plain.end(at: 1.5) == expected)
        }
    }

    @Test func settleFractionFollowsTheCurve() {
        let easeOut = (0.25, 0.6, 0.4, 1.0)
        #expect(SlotSwipe.settleFraction(elapsed: 0, duration: 0.2, curve: easeOut) == 0)
        #expect(SlotSwipe.settleFraction(elapsed: 0.3, duration: 0.2, curve: easeOut) == 1)
        let half = SlotSwipe.settleFraction(elapsed: 0.1, duration: 0.2, curve: easeOut)
        #expect(half > 0.5 && half < 1)
        // Linear control points give linear timing.
        let linear = SlotSwipe.settleFraction(elapsed: 0.05, duration: 0.2, curve: (1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3))
        #expect(abs(linear - 0.25) < 1e-6)
        var previous = 0.0
        for step in 1...20 {
            let value = SlotSwipe.settleFraction(elapsed: Double(step) / 100, duration: 0.2, curve: easeOut)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test func nearestSlotPrefersAvailableColumns() {
        #expect(SlotSwipe.nearestSlot(0.7, available: [-1, 0, 1]) == 1)
        #expect(SlotSwipe.nearestSlot(0.3, available: [-1, 0, 1]) == 0)
        #expect(SlotSwipe.nearestSlot(-0.8, available: [0, 1]) == 0)
    }

    @Test func pathLegsMeetAtTheirEnds() {
        // At rest: straight from the column.
        #expect(SlotSwipe.leg(0.4, offset: 0) == .fromColumn(.right, 0.4))
        #expect(SlotSwipe.leg(-0.4, offset: 0) == .fromColumn(.left, 0.4))
        // Caught at -0.3: towards the column, the left neighbour beyond.
        #expect(SlotSwipe.leg(-0.3, offset: -0.3) == .toColumn(0))
        #expect(SlotSwipe.leg(-0.15, offset: -0.3) == .toColumn(0.5))
        #expect(SlotSwipe.leg(0, offset: -0.3) == .toColumn(1))
        #expect(SlotSwipe.leg(0.5, offset: -0.3) == .fromColumn(.right, 0.5))
        guard case .fromCaught(.left, let u) = SlotSwipe.leg(-1, offset: -0.3) else { Issue.record("leg"); return }
        #expect(abs(u - 1) < 1e-9)
    }
}
