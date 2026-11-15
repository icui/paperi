import Foundation
@preconcurrency import ApplicationServices
import PaperiCore

/// Writes window frames off the main thread during a gap drag.
///
/// An AX write blocks until the target app has handled it, often 10–30 ms
/// per window. On the main thread that stalled everything else, including
/// moving the gap handle, which could only catch up once every window was
/// written. Here each window has its own lane: windows of different apps
/// are written at the same time, and a window still busy with one write
/// only gets the latest target when it is done (intermediate ones are
/// dropped), so a slow app never builds up a backlog.
final class FrameWriter: @unchecked Sendable {
    struct Result: Sendable {
        let windowID: UInt32
        let slotID: String
        let wanted: Rect
        /// The frame last written before this one (nil if none was known).
        let previous: Rect?
        /// The size the app actually took, read back; nil if a write failed.
        let actual: CGSize?
    }

    private struct Job { let element: AXUIElement; let slotID: String; let frame: Rect }

    private let lock = NSLock()
    private var pending: [UInt32: Job] = [:]
    private var written: [UInt32: Rect] = [:]
    private var busy: Set<UInt32> = []
    private let queue = DispatchQueue(label: "dev.paperi.frame-writer", qos: .userInteractive, attributes: .concurrent)
    /// Called on the writing thread after each write.
    var onResult: (@Sendable (Result) -> Void)?

    /// Queues `frame` for the window; `current` is where it is now if this
    /// writer has not written it yet.
    func submit(windowID: UInt32, slotID: String, element: AXUIElement, frame: Rect, current: Rect?) {
        lock.lock()
        if written[windowID] == nil, let current { written[windowID] = current }
        pending[windowID] = Job(element: element, slotID: slotID, frame: frame)
        let start = busy.insert(windowID).inserted
        lock.unlock()
        if start { queue.async { self.drain(windowID) } }
    }

    /// Forgets what was written, for the next drag.
    func reset() {
        lock.lock(); written.removeAll(); lock.unlock()
    }

    private func drain(_ windowID: UInt32) {
        while true {
            lock.lock()
            guard let job = pending.removeValue(forKey: windowID) else {
                busy.remove(windowID); lock.unlock(); return
            }
            let previous = written[windowID]
            lock.unlock()
            let actual = Self.write(job.frame, from: previous, to: job.element)
            lock.lock(); written[windowID] = job.frame; lock.unlock()
            onResult?(Result(windowID: windowID, slotID: job.slotID, wanted: job.frame, previous: previous, actual: actual))
        }
    }

    /// Writes only what changed, ordered so the window briefly overlaps its
    /// neighbour rather than leaving a gap: a growing window is sized before
    /// it is moved, a shrinking one moved before it is sized. Returns the
    /// size the app actually took (read back, since an app at a size limit
    /// clamps the write), or nil if a write failed.
    static func write(_ frame: Rect, from previous: Rect?, to element: AXUIElement) -> CGSize? {
        var point = CGPoint(x: frame.x, y: frame.y), size = CGSize(width: frame.width, height: frame.height)
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return nil }
        let moved = previous.map { $0.x != frame.x || $0.y != frame.y } ?? true
        let resized = previous.map { $0.width != frame.width || $0.height != frame.height } ?? true
        let growing = previous.map { frame.width * frame.height > $0.width * $0.height } ?? true
        var writes: [(CFString, AXValue)] = []
        if resized && growing { writes.append((kAXSizeAttribute as CFString, s)) }
        if moved { writes.append((kAXPositionAttribute as CFString, p)) }
        if resized && !growing { writes.append((kAXSizeAttribute as CFString, s)) }
        for (name, value) in writes where AXUIElementSetAttributeValue(element, name, value) != .success { return nil }
        guard resized else { return size }
        guard let value = Diagnostics.attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var actual = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &actual) ? actual : nil
    }
}
