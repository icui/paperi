import PaperiCore

/// Saves admission geometry independently of management state. Restoration is a
/// one-shot cleanup phase, permitted only after management has been stopped.
struct FrameRestorationJournal {
    private var originals: [UInt32: Rect] = [:]
    private var finished = false

    var count: Int { originals.count }

    @discardableResult mutating func remember(windowID: UInt32, frame: Rect) -> Bool {
        guard !finished, windowID > 0, frame.isValid else { return false }
        if originals[windowID] == nil { originals[windowID] = frame }
        return true
    }

    mutating func remove(windowID: UInt32) { originals.removeValue(forKey: windowID) }

    mutating func restore(managementStopped: Bool, perform: (UInt32, Rect) -> Bool) -> [UInt32: Bool]? {
        guard managementStopped, !finished else { return nil }
        finished = true
        var results: [UInt32: Bool] = [:]
        for id in originals.keys.sorted() { results[id] = perform(id, originals[id]!) }
        return results
    }
}
