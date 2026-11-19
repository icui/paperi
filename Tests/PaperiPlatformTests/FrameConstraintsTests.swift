import Testing
import PaperiCore
@testable import PaperiPlatform

struct FrameConstraintsTests {
    let target = Rect(x: 704, y: 38, width: 720, height: 886)
    let rounded = Rect(x: 704, y: 38, width: 720, height: 889)

    @Test func roundedSizeSettlesAfterTwoIdenticalWrites() {
        var constraints = FrameConstraints()
        // First write: the window is still at its pre-Paperi frame.
        let r1 = constraints.settles(1, at: Rect(x: 0, y: 0, width: 500, height: 500), for: target)
        #expect(!r1)
        // Second write: the app rounded the first one.
        let r2 = constraints.settles(1, at: rounded, for: target)
        #expect(!r2)
        #expect(constraints.settledFrame(1, for: target) == nil)
        // Rounded again: it keeps that size, so stop writing.
        let r3 = constraints.settles(1, at: rounded, for: target)
        #expect(r3)
        #expect(constraints.settledFrame(1, for: target) == rounded)
        // A new target needs its own proof.
        let shorter = Rect(x: 704, y: 38, width: 720, height: 439)
        #expect(constraints.settledFrame(1, for: shorter) == nil)
        constraints.forget(1)
        #expect(constraints.settledFrame(1, for: target) == nil)
    }

    @Test func ignoredOrMisplacedWritesNeverSettle() {
        var constraints = FrameConstraints()
        // An app that ignores writes stays where it was.
        let elsewhere = Rect(x: 100, y: 100, width: 720, height: 886)
        let r4 = constraints.settles(2, at: elsewhere, for: target)
        #expect(!r4)
        let r5 = constraints.settles(2, at: elsewhere, for: target)
        #expect(!r5)
        // Far larger than any rounding.
        let tall = Rect(x: 704, y: 38, width: 720, height: 600)
        let r6 = constraints.settles(3, at: tall, for: target)
        #expect(!r6)
        let r7 = constraints.settles(3, at: tall, for: target)
        #expect(!r7)
        // A different frame each time is not settling either.
        let r8 = constraints.settles(4, at: rounded, for: target)
        #expect(!r8)
        let r9 = constraints.settles(4, at: Rect(x: 704, y: 38, width: 720, height: 875), for: target)
        #expect(!r9)
    }

    @Test func settledSizeCountsForMovedTargetsOfTheSameSize() {
        var constraints = FrameConstraints()
        // Terminal keeps whole rows: 5 points taller than a stacked target.
        let stacked = Rect(x: 1378, y: 502, width: 776, height: 422)
        let kept = Rect(x: 1378, y: 503, width: 776, height: 427)
        #expect(!constraints.keepsSize(5, kept, for: stacked))
        _ = constraints.settles(5, at: kept, for: stacked)
        _ = constraints.settles(5, at: kept, for: stacked)
        // A scroll moves the target but keeps its size.
        var scrolled = stacked; scrolled.x -= 700
        var slid = kept; slid.x -= 700
        #expect(constraints.keepsSize(5, slid, for: scrolled))
        // A resized target, or a window at another size, needs its own proof.
        var taller = stacked; taller.height += 40
        #expect(!constraints.keepsSize(5, slid, for: taller))
        var grown = slid; grown.height += 15
        #expect(!constraints.keepsSize(5, grown, for: scrolled))
    }
}
