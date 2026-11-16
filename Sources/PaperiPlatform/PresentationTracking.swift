import Foundation

/// Per-app Accessibility responsiveness. One policy for every slow-app case:
/// a timeout backs the app off, doubling from a short first delay, so a hung
/// app is soon surveyed rarely while a briefly busy one (activation, a Dock
/// minimize or restore effect) is retried quickly.
struct AppResponsiveness {
    static let firstDelay = 0.25
    static let maxDelay = 5.0
    /// Notifications may shorten this many consecutive backoffs. A hung app
    /// that still posts cannot cost a timeout on every pass.
    static let eventRetries = 3

    private var failures: [pid_t: Int] = [:]
    private var until: [pid_t: Double] = [:]

    func available(_ pid: pid_t, now: Double) -> Bool { (until[pid] ?? 0) <= now }

    /// Returns the delay before the next attempt.
    @discardableResult mutating func timedOut(_ pid: pid_t, now: Double) -> Double {
        let count = (failures[pid] ?? 0) + 1
        failures[pid] = count
        let delay = min(Self.maxDelay, Self.firstDelay * pow(2, Double(count - 1)))
        until[pid] = now + delay
        return delay
    }

    mutating func answered(_ pid: pid_t) {
        failures.removeValue(forKey: pid); until.removeValue(forKey: pid)
    }

    /// The app posted a notification, so it is servicing Accessibility again.
    mutating func heard(_ pid: pid_t, now: Double) {
        guard let count = failures[pid], count <= Self.eventRetries,
              let next = until[pid], next > now else { return }
        until[pid] = now
    }

    mutating func retain(_ live: Set<pid_t>) {
        failures = failures.filter { live.contains($0.key) }
        until = until.filter { live.contains($0.key) }
    }
}

/// Windows whose minimize is known before a survey can confirm it. The owner
/// answers no Accessibility call during the Dock effect, so a survey then
/// either times out or still reports the old state.
struct MinimizeTracker {
    enum Entry: Equatable {
        /// Paperi's own request succeeded. Its owner cannot move any of its
        /// windows until the effect ends, so the Space's effects wait for
        /// confirmation, or the deadline (the app ignored the request).
        case requested(space: UInt64, until: Double)
        /// The owner reported the minimize.
        case notified
    }

    static let requestTimeout = 2.0
    private(set) var entries: [UInt32: Entry] = [:]

    func contains(_ wid: UInt32) -> Bool { entries[wid] != nil }

    /// Minimized whatever a stale or unanswered survey says.
    var notified: Set<UInt32> { Set(entries.filter { $0.value == .notified }.keys) }

    /// Windows whose owner has not yet confirmed Paperi's request.
    func pendingWindows(now: Double) -> Set<UInt32> {
        Set(entries.compactMap { wid, entry in
            if case .requested(_, let until) = entry, now < until { return wid }
            return nil
        })
    }

    /// Spaces whose window effects wait for an owner to confirm a minimize.
    func pendingSpaces(now: Double) -> Set<UInt64> {
        Set(entries.values.compactMap { entry in
            if case .requested(let space, let until) = entry, now < until { return space }
            return nil
        })
    }

    mutating func requested(_ wid: UInt32, space: UInt64, now: Double) {
        guard entries[wid] != .notified else { return }
        entries[wid] = .requested(space: space, until: now + Self.requestTimeout)
    }

    mutating func minimizeNotified(_ wid: UInt32) { entries[wid] = .notified }
    mutating func restoreNotified(_ wid: UInt32) { forget(wid) }
    mutating func forget(_ wid: UInt32) { entries.removeValue(forKey: wid) }

    /// A fresh survey reading (never a carried-forward row). Confirmation
    /// hands the window to ordinary observation; after the owner reported a
    /// minimize, a definite "not minimized" means a restore whose
    /// notification was lost. A pending request ignores "not minimized":
    /// the effect may not have started.
    mutating func observe(_ wid: UInt32, minimized: Bool?) {
        guard let entry = entries[wid], let minimized else { return }
        if minimized || entry == .notified { forget(wid) }
    }

    mutating func expire(now: Double) {
        entries = entries.filter { _, entry in
            if case .requested(_, let until) = entry { return now < until }
            return true
        }
    }

    mutating func retain(where keep: (UInt32) -> Bool) {
        entries = entries.filter { keep($0.key) }
    }
}
