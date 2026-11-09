import Foundation

/// Commands come only from the freshly launched preview and its known windows.
/// A per-run token and monotonic sequence reject stale/replayed log records.
struct PreviewCommandInbox {
    enum Action: String { case grow, shrink, slurp, barf, stop }
    struct Command { let action: Action; let windowID: UInt32; let source: String }
    let pid: pid_t
    let token: String
    private(set) var lastSequence = 0

    mutating func consume(_ row: [String: Any], knownWindows: Set<UInt32>) -> Command? {
        guard row["event"] as? String == "previewCommand", row["pid"] as? Int32 == pid,
              row["previewToken"] as? String == token,
              let sequence = row["sequence"] as? Int, sequence > lastSequence,
              let id = row["commandWindowID"] as? UInt32, knownWindows.contains(id),
              let value = row["command"] as? String, let action = Action(rawValue: value),
              let source = row["source"] as? String, ["button", "keyEquivalent"].contains(source) else { return nil }
        lastSequence = sequence
        return Command(action: action, windowID: id, source: source)
    }
}
