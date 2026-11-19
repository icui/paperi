import PaperiCore

/// Apps that size windows in fixed increments never land exactly on a written
/// frame: Terminal rounds its height to whole text rows (886 becomes 889).
/// Without this, every pass would see the mismatch and write the same frame
/// again. A window found at the same nearby frame before two consecutive
/// writes of one target has settled there: the frame counts as placed.
struct FrameConstraints {
    /// Largest size difference an app may round by; anything further off is
    /// not the window settling (e.g. an app that ignored the write).
    static let maxSnap = 48.0
    private var written: [UInt32: (target: Rect, found: Rect)] = [:]
    private var settled: [UInt32: (target: Rect, frame: Rect)] = [:]

    /// The frame the window settled at for `target`, if it has.
    func settledFrame(_ wid: UInt32, for target: Rect) -> Rect? {
        settled[wid].flatMap { $0.target == target ? $0.frame : nil }
    }

    /// True when the window settled at `actual`'s size for a target of
    /// `target`'s size. Position-only motion (a scroll moves the target, not
    /// its size) can then slide the window at the size it keeps.
    func keepsSize(_ wid: UInt32, _ actual: Rect, for target: Rect) -> Bool {
        guard let entry = settled[wid] else { return false }
        return abs(entry.target.width - target.width) <= 0.5 && abs(entry.target.height - target.height) <= 0.5
            && abs(entry.frame.width - actual.width) <= 1 && abs(entry.frame.height - actual.height) <= 1
    }

    /// Called instead of writing `target` to a window found at `frame`. True
    /// when the previous write of this target also found the window there,
    /// with its position honoured and its size only rounded: it has settled,
    /// and the write is skipped.
    mutating func settles(_ wid: UInt32, at frame: Rect, for target: Rect) -> Bool {
        if let last = written[wid], last.target == target, Self.near(last.found, frame, 1), Self.rounded(frame, target) {
            written.removeValue(forKey: wid)
            settled[wid] = (target, frame)
            return true
        }
        written[wid] = (target, frame)
        return false
    }

    mutating func forget(_ wid: UInt32) {
        written.removeValue(forKey: wid); settled.removeValue(forKey: wid)
    }

    static func rounded(_ frame: Rect, _ target: Rect) -> Bool {
        abs(frame.x - target.x) <= 2 && abs(frame.y - target.y) <= 2
            && abs(frame.width - target.width) <= maxSnap && abs(frame.height - target.height) <= maxSnap
    }

    private static func near(_ a: Rect, _ b: Rect, _ tolerance: Double) -> Bool {
        zip([a.x, a.y, a.width, a.height], [b.x, b.y, b.width, b.height]).allSatisfy { abs($0 - $1) <= tolerance }
    }
}
