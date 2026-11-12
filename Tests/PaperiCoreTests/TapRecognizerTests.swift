import Testing
@testable import PaperiCore

struct TapRecognizerTests {
    typealias Recognizer = TapRecognizer<Int>

    /// One finger's contact: lands at `down`, lifts at `up`, moving linearly
    /// by `move` millimetres (x) while down. Lift frames report `liftJump`
    /// extra displacement, as a leaving pad does.
    struct Finger {
        var down: Double, up: Double, move = 0.0, liftJump = 0.0
    }

    /// Replays fingers as 120 Hz frames (plus exact landing and lift frames)
    /// and returns the verdict of the final sequence.
    func run(_ fingers: [Finger], start: Double = 10, clickAt: Double? = nil,
             recognizer: inout Recognizer) -> Recognizer.Verdict? {
        var times = Set<Double>()
        for f in fingers { times.insert(f.down); times.insert(f.up) }
        let end = fingers.map(\.up).max()!
        var t = fingers.map(\.down).min()!
        while t < end { times.insert(t); t += 1.0 / 120 }
        var result: Recognizer.Verdict?
        for local in times.sorted() {
            let time = start + local
            let contacts: [Recognizer.Contact] = fingers.enumerated().compactMap { i, f in
                guard local >= f.down, local <= f.up else { return nil }
                let fraction = f.up > f.down ? (local - f.down) / (f.up - f.down) : 0
                let lifting = local == f.up
                return .init(id: i, x: Double(i) * 20 + f.move * fraction + (lifting ? f.liftJump : 0),
                             y: 50, down: !lifting)
            }
            guard !contacts.isEmpty else { continue }
            let clicked = clickAt.map { abs(local - $0) < 0.03 } ?? false
            if let (_, verdict) = recognizer.observe(contacts, at: time, clicked: clicked) { result = verdict }
        }
        return result
    }

    func verdict(_ fingers: [Finger], clickAt: Double? = nil) -> Recognizer.Verdict? {
        var recognizer = Recognizer(fingers: 3)
        return run(fingers, clickAt: clickAt, recognizer: &recognizer)
    }

    // Deliberate taps, from crisp to sloppy: all must trigger.

    @Test func crispTap() {
        #expect(verdict([.init(down: 0, up: 0.08), .init(down: 0.005, up: 0.085), .init(down: 0.01, up: 0.09)]) == .tap)
    }

    @Test func sloppyTapAtEveryLimitStillTriggers() {
        // 90 ms landing spread, ~230 ms hold, 90 ms lift spread, 2 mm roll,
        // and a 4 mm jump on the lift frame (ignored).
        #expect(verdict([.init(down: 0, up: 0.32, move: 2, liftJump: 4),
                         .init(down: 0.05, up: 0.36, move: -1.5),
                         .init(down: 0.09, up: 0.41, move: 1)]) == .tap)
    }

    @Test func tapRightAfterPointerMoveTriggers() {
        var recognizer = Recognizer(fingers: 3)
        // One finger moves the pointer, lifts, and the tap follows at once.
        _ = run([.init(down: 0, up: 0.5, move: 30)], start: 10, recognizer: &recognizer)
        #expect(run([.init(down: 0, up: 0.1), .init(down: 0.01, up: 0.1), .init(down: 0.02, up: 0.11)],
                    start: 10.6, recognizer: &recognizer) == .tap)
    }

    @Test func consecutiveTapsBothTrigger() {
        var recognizer = Recognizer(fingers: 3)
        let tap: [Finger] = [.init(down: 0, up: 0.1), .init(down: 0.01, up: 0.1), .init(down: 0.02, up: 0.11)]
        #expect(run(tap, start: 10, recognizer: &recognizer) == .tap)
        #expect(run(tap, start: 10.5, recognizer: &recognizer) == .tap)
    }

    // Other trackpad use: none may trigger.

    @Test func shortSwipeIsRejected() {
        #expect(verdict([.init(down: 0, up: 0.15, move: 8), .init(down: 0.01, up: 0.15, move: 8),
                         .init(down: 0.02, up: 0.16, move: 8)]) == .rejected("moved"))
    }

    @Test func barelyLockedSwipeIsRejected() {
        #expect(verdict([.init(down: 0, up: 0.12, move: 3), .init(down: 0.01, up: 0.12, move: 3),
                         .init(down: 0.02, up: 0.12, move: 3)]) == .rejected("moved"))
    }

    @Test func restingFingersAreRejected() {
        #expect(verdict([.init(down: 0, up: 0.6), .init(down: 0.01, up: 0.6), .init(down: 0.02, up: 0.6)])
                == .rejected("held"))
    }

    @Test func fingersPlacedOneByOneAreRejected() {
        #expect(verdict([.init(down: 0, up: 0.4), .init(down: 0.15, up: 0.4), .init(down: 0.3, up: 0.4)])
                == .rejected("staggered landing"))
    }

    @Test func fingersLiftedOneByOneAreRejected() {
        #expect(verdict([.init(down: 0, up: 0.1), .init(down: 0.01, up: 0.25), .init(down: 0.02, up: 0.4)])
                == .rejected("staggered lift"))
    }

    @Test func physicalClickIsRejected() {
        #expect(verdict([.init(down: 0, up: 0.12), .init(down: 0.01, up: 0.12), .init(down: 0.02, up: 0.13)],
                        clickAt: 0.06) == .rejected("clicked"))
    }

    @Test func fourFingersAreRejected() {
        #expect(verdict([.init(down: 0, up: 0.1), .init(down: 0.01, up: 0.1),
                         .init(down: 0.02, up: 0.11), .init(down: 0.03, up: 0.11)]) == .rejected("4 fingers"))
    }

    @Test func twoFingerTapIsIgnored() {
        #expect(verdict([.init(down: 0, up: 0.1), .init(down: 0.01, up: 0.1)]) == nil)
    }

    @Test func bounceAfterSwipeIsRejected() {
        var recognizer = Recognizer(fingers: 3)
        _ = run([.init(down: 0, up: 0.3, move: 40), .init(down: 0, up: 0.3, move: 40), .init(down: 0, up: 0.3, move: 40)],
                start: 10, recognizer: &recognizer)
        #expect(run([.init(down: 0, up: 0.08), .init(down: 0, up: 0.08), .init(down: 0.01, up: 0.09)],
                    start: 10.42, recognizer: &recognizer) == .rejected("too soon after a gesture"))
    }

    @Test func fingerReturningBeforeLiftIsRejected() {
        var recognizer = Recognizer(fingers: 3)
        let contacts = { (ids: [Int], down: Bool) in ids.map { Recognizer.Contact(id: $0, x: 0, y: 0, down: down) } }
        #expect(recognizer.observe(contacts([1, 2, 3], true), at: 1) == nil)
        #expect(recognizer.observe(contacts([1], false) + contacts([2, 3], true), at: 1.05) == nil)
        #expect(recognizer.observe(contacts([2, 3, 4], true), at: 1.07) == nil)
        #expect(recognizer.observe(contacts([2, 3, 4], false), at: 1.1)?.1 == .rejected("retouched"))
    }

    @Test func unreportedLiftDoesNotPoisonNextTap() {
        var recognizer = Recognizer(fingers: 3)
        let contacts = { (ids: [Int], down: Bool) in ids.map { Recognizer.Contact(id: $0, x: 0, y: 0, down: down) } }
        _ = recognizer.observe(contacts([1, 2, 3], true), at: 1)
        // No lift frame; the next tap starts well after.
        _ = recognizer.observe(contacts([4, 5, 6], true), at: 2)
        #expect(recognizer.observe(contacts([4, 5, 6], false), at: 2.1)?.1 == .tap)
    }
}
