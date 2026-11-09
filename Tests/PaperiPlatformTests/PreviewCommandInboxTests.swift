import Testing
@testable import PaperiPlatform

struct PreviewCommandInboxTests {
    func row(_ sequence: Int = 1) -> [String: Any] {
        ["event": "previewCommand", "pid": Int32(42), "previewToken": "current", "sequence": sequence,
         "commandWindowID": UInt32(1), "command": "grow", "source": "keyEquivalent"]
    }
    @Test func acceptsCurrentKnownWindowAndRejectsReplay() {
        var inbox = PreviewCommandInbox(pid: 42, token: "current")
        #expect(inbox.consume(row(), knownWindows: [1])?.action == .grow)
        #expect(inbox.consume(row(), knownWindows: [1]) == nil)
        var stop = row(2); stop["command"] = "stop"; stop["source"] = "button"
        #expect(inbox.consume(stop, knownWindows: [1])?.action == .stop)
        var slurp = row(3); slurp["command"] = "slurp"; slurp["source"] = "keyEquivalent"
        #expect(inbox.consume(slurp, knownWindows: [1])?.action == .slurp)
        var barf = row(4); barf["command"] = "barf"; barf["source"] = "button"
        #expect(inbox.consume(barf, knownWindows: [1])?.action == .barf)
    }
    @Test func foreignStaleUnknownAndMalformedInputsDoNotAdvanceInbox() {
        var inbox = PreviewCommandInbox(pid: 42, token: "current")
        for (key, value): (String, Any) in [("pid", Int32(99)), ("previewToken", "old"),
            ("commandWindowID", UInt32(2)), ("command", "arbitrary"), ("sequence", 0), ("source", "global")] {
            var invalid = row(); invalid[key] = value
            #expect(inbox.consume(invalid, knownWindows: [1]) == nil)
            #expect(inbox.lastSequence == 0)
        }
        #expect(inbox.consume(row(), knownWindows: [1])?.action == .grow)
    }
}
