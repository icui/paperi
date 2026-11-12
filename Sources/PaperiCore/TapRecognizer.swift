import Foundation

/// Pure recognizer for a quick tap of exactly `fingers` fingers. No OS effects.
///
/// One contact sequence runs from the first finger landing on an empty
/// trackpad until the last one lifts. It is a tap only if every limit below
/// holds; anything else (a swipe, resting fingers, a physical click, a
/// fourth finger, fingers placed one by one) is rejected.
///
/// The limits sit between what deliberate taps do and what other trackpad use
/// does:
/// - Fingers placed together land within ~10–50 ms of each other and lift
///   within about the same spread. Fingers put down or lifted one at a time
///   take well over 150 ms. Both spreads allow 100 ms.
/// - A tap stays down about 60–150 ms. Resting fingers and the pause before
///   a swipe stay longer. 250 ms of full contact still covers slow taps.
/// - Contact centroids shift about 0.5–1.5 mm as finger pads flatten and roll.
///   The swipe lock needs 1.5–2.4 mm of mean travel and real swipes travel
///   far more, so 2.5 mm per finger keeps sloppy taps without taking swipes.
///   Positions while lifting are ignored: they jump as a pad leaves.
/// - Fingers often bounce back right after a swipe or scroll. A tap must
///   start 250 ms after any earlier multi-finger sequence; a single-finger
///   pointer move just before a tap is fine.
public struct TapRecognizer<ID: Hashable> {
    public struct Thresholds: Equatable, Sendable {
        /// First finger down to all fingers down, seconds.
        public var landingSpread: Double
        /// All fingers down to the first lift, seconds.
        public var hold: Double
        /// First lift to the last lift, seconds.
        public var liftSpread: Double
        /// Largest distance any finger moves while down, millimetres.
        public var travel: Double
        /// Required gap after an earlier multi-finger sequence, seconds.
        public var quietAfterGesture: Double
        /// Frames further apart than this abandon a sequence whose final
        /// lift was never reported, seconds.
        public var staleGap: Double

        public init(landingSpread: Double = 0.10, hold: Double = 0.25, liftSpread: Double = 0.10,
                    travel: Double = 2.5, quietAfterGesture: Double = 0.25, staleGap: Double = 0.5) {
            self.landingSpread = landingSpread
            self.hold = hold
            self.liftSpread = liftSpread
            self.travel = travel
            self.quietAfterGesture = quietAfterGesture
            self.staleGap = staleGap
        }
    }

    public struct Contact {
        public var id: ID
        /// Position on the trackpad in millimetres.
        public var x: Double
        public var y: Double
        /// False once the finger has lifted (or was cancelled).
        public var down: Bool
        public init(id: ID, x: Double, y: Double, down: Bool) {
            self.id = id; self.x = x; self.y = y; self.down = down
        }
    }

    /// Measurements of one finished sequence, for the verdict and for logs.
    public struct Sample: Equatable, Sendable {
        public var landingSpread: Double
        public var hold: Double
        public var liftSpread: Double
        public var travel: Double
        public var peakFingers: Int
        public var clicked: Bool
        public var cancelled: Bool
        /// A finger landed again after the first lift.
        public var retouched: Bool
        /// Time since the previous multi-finger sequence ended.
        public var quietBefore: Double

        public var summary: String {
            func ms(_ s: Double) -> String { String(format: "%.0fms", s * 1000) }
            return "fingers=\(peakFingers) landing=\(ms(landingSpread)) hold=\(ms(hold)) lift=\(ms(liftSpread)) "
                + String(format: "travel=%.2fmm", travel)
                + (quietBefore.isFinite ? " quiet=\(ms(quietBefore))" : "")
                + (clicked ? " clicked" : "") + (cancelled ? " cancelled" : "") + (retouched ? " retouched" : "")
        }
    }

    public enum Verdict: Equatable, Sendable {
        case tap
        case rejected(String)
    }

    public let fingers: Int
    public var thresholds: Thresholds

    private var start: Double?
    private var lastFrame = -Double.infinity
    private var allDown: Double?
    private var firstLift: Double?
    private var origins: [ID: (x: Double, y: Double)] = [:]
    private var travel = 0.0
    private var peak = 0
    private var clicked = false
    private var cancelled = false
    private var retouched = false
    private var quietBefore = Double.infinity
    private var previousEnd = -Double.infinity

    public init(fingers: Int, thresholds: Thresholds = Thresholds()) {
        self.fingers = fingers
        self.thresholds = thresholds
    }

    public func classify(_ s: Sample) -> Verdict {
        if s.peakFingers != fingers { return .rejected("\(s.peakFingers) fingers") }
        if s.clicked { return .rejected("clicked") }
        if s.cancelled { return .rejected("cancelled") }
        if s.retouched { return .rejected("retouched") }
        if s.quietBefore < thresholds.quietAfterGesture { return .rejected("too soon after a gesture") }
        if s.landingSpread > thresholds.landingSpread { return .rejected("staggered landing") }
        if s.hold > thresholds.hold { return .rejected("held") }
        if s.liftSpread > thresholds.liftSpread { return .rejected("staggered lift") }
        if s.travel > thresholds.travel { return .rejected("moved") }
        return .tap
    }

    /// Feeds one touch frame. Returns the sample and verdict when a sequence
    /// that reached `fingers` contacts ends; nil otherwise. `clicked` reports
    /// a pressed mouse button; `cancelled` a contact the system cancelled.
    public mutating func observe(_ contacts: [Contact], at time: Double,
                                 clicked: Bool = false, cancelled: Bool = false) -> (Sample, Verdict)? {
        if start != nil, time - lastFrame > thresholds.staleGap {
            // The final lift was never reported; this frame starts afresh.
            finish(at: lastFrame)
        }
        lastFrame = time
        let down = contacts.filter(\.down)
        if start == nil {
            guard !down.isEmpty else { return nil }
            start = time
            quietBefore = time - previousEnd
        }
        for contact in down {
            if let origin = origins[contact.id] {
                travel = max(travel, hypot(contact.x - origin.x, contact.y - origin.y))
            } else {
                if firstLift != nil { retouched = true }
                origins[contact.id] = (contact.x, contact.y)
            }
        }
        peak = max(peak, down.count)
        self.clicked = self.clicked || clicked
        self.cancelled = self.cancelled || cancelled
        if allDown == nil, down.count >= fingers { allDown = time }
        if allDown != nil, firstLift == nil, down.count < fingers { firstLift = time }
        guard down.isEmpty else { return nil }
        let sample = Sample(landingSpread: (allDown ?? time) - start!,
                            hold: (firstLift ?? time) - (allDown ?? time),
                            liftSpread: time - (firstLift ?? time),
                            travel: travel, peakFingers: peak, clicked: self.clicked,
                            cancelled: self.cancelled, retouched: retouched, quietBefore: quietBefore)
        let reached = peak >= fingers
        finish(at: time)
        return reached ? (sample, classify(sample)) : nil
    }

    private mutating func finish(at time: Double) {
        // Only multi-finger sequences (scrolls, swipes, taps) hold off a tap.
        if peak >= 2 { previousEnd = time }
        start = nil
        allDown = nil
        firstLift = nil
        origins.removeAll()
        travel = 0
        peak = 0
        clicked = false
        cancelled = false
        retouched = false
    }
}
