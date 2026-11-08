import PaperiCore

/// Expected frames belong to one adapter lifetime and expire. A mismatch is
/// observable immediately, even while a write is pending; watchers stay enabled.
struct FrameEchoes {
    enum Observation: Equatable { case expected(UInt64), external }
    private struct Request { let generation: UInt64; let frame: Rect; let deadline: Double }
    private var pending: [UInt32: Request] = [:]
    private var generation: UInt64 = 0

    @discardableResult mutating func expect(windowID: UInt32, frame: Rect, now: Double,
                                            timeout: Double = 1.5) -> UInt64? {
        guard windowID != 0, frame.isValid, now.isFinite, timeout.isFinite,
              timeout > 0, timeout <= 5, (now + timeout).isFinite else { return nil }
        generation &+= 1
        pending[windowID] = Request(generation: generation, frame: frame, deadline: now + timeout)
        return generation
    }

    mutating func observe(windowID: UInt32, frame: Rect, now: Double) -> Observation {
        guard let request = pending[windowID] else { return .external }
        guard now.isFinite, frame.isValid, now <= request.deadline,
              zip([frame.x, frame.y, frame.width, frame.height],
                  [request.frame.x, request.frame.y, request.frame.width, request.frame.height])
                .allSatisfy({ abs($0 - $1) <= 2 }) else {
            pending.removeValue(forKey: windowID)
            return .external
        }
        // More than one notification can describe the same write sequence.
        return .expected(request.generation)
    }

    mutating func remove(windowID: UInt32) { pending.removeValue(forKey: windowID) }
}
