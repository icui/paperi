import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

extension Diagnostics {
    /// An opt-in effect spike, restricted to a child process we launch ourselves.
    /// No caller-supplied PID, reference or window ID is accepted.
    @MainActor public static func probePlacement() -> [String: Any] {
        var report: [String: Any] = ["schemaVersion": 1, "result": "failed",
            "scope": "New disposable child window only; no focus, hotkeys or Space writes"]
        guard AXIsProcessTrusted() else {
            report["reason"] = "Accessibility trust required; no fixture launched"
            return report
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperi-placement-\(UUID())")
        let child = Process()
        defer {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { report["reason"] = "Cannot create fixture log directory"; return report }
        let log = directory.appendingPathComponent("fixture.jsonl")
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("PaperiAXFixture")
        child.arguments = [log.path, "--placement"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { report["reason"] = "Cannot launch sibling PaperiAXFixture; build all products first"; return report }
        let pid = child.processIdentifier
        report["fixturePID"] = pid
        func pause() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
        var wid: UInt32?
        while child.isRunning && ProcessInfo.processInfo.systemUptime < readyDeadline {
            let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
            for line in lines {
                if let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   row["event"] as? String == "placementReady", row["pid"] as? Int32 == pid,
                   let id = row["documentID"] as? UInt32, id > 0 { wid = id }
            }
            if wid != nil { break }
            pause()
        }
        guard let wid, child.isRunning else { report["reason"] = "Fixture readiness unavailable"; return report }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var window: AXUIElement?
        let discoveryDeadline = ProcessInfo.processInfo.systemUptime + 2
        while child.isRunning && ProcessInfo.processInfo.systemUptime < discoveryDeadline {
            let refs = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            window = refs.first { paperi_window_id($0) == wid }
            if window != nil { break }
            pause()
        }
        guard let window, let original = frame(window) else {
            report["reason"] = "No fresh matching AX window/frame"; return report
        }
        AXUIElementSetMessagingTimeout(window, 0.15)
        func identityValid() -> Bool {
            var owner: pid_t = 0
            return child.isRunning && AXUIElementGetPid(window, &owner) == .success && owner == pid &&
                paperi_window_id(window) == wid && attribute(window, kAXRoleAttribute) as? String == "AXWindow"
        }
        var movable = DarwinBoolean(false), resizable = DarwinBoolean(false)
        let moveError = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
        let sizeError = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable)
        let parent = attribute(window, kAXParentAttribute)
        let level = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?
            .first?[kCGWindowLayer as String] as? Int
        let facts = WindowFacts(bundleID: "dev.paperi.disposable-placement",
            role: attribute(window, kAXRoleAttribute) as? String,
            subrole: attribute(window, kAXSubroleAttribute) as? String,
            isRoot: parent.map { CFEqual($0, application) },
            movable: moveError == .success ? movable.boolValue : nil,
            resizable: sizeError == .success ? resizable.boolValue : nil,
            fullscreen: attribute(window, "AXFullScreen") as? Bool,
            minimized: attribute(window, kAXMinimizedAttribute) as? Bool, level: level)
        let classification = WindowPolicy.classify(facts)
        report["eligibility"] = classification.eligibility.rawValue
        guard identityValid(), original.isValid, classification.eligibility == .tiled else {
            report["reason"] = "Fixture not eligible: \(classification.reason)"; return report
        }
        func json(_ rect: Rect) -> [String: Double] {
            ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]
        }
        func matches(_ rect: Rect, _ other: Rect) -> Bool {
            zip([rect.x, rect.y, rect.width, rect.height], [other.x, other.y, other.width, other.height])
                .allSatisfy { abs($0 - $1) <= 2 }
        }
        func write(_ rect: Rect) -> [Int32] {
            guard identityValid(), rect.isValid else { return [] }
            var point = CGPoint(x: rect.x, y: rect.y)
            var size = CGSize(width: rect.width, height: rect.height)
            guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return [] }
            return [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)].map { name, value in
                guard identityValid() else { return AXError.invalidUIElement.rawValue }
                return AXUIElementSetAttributeValue(window, name as CFString, value).rawValue
            }
        }
        func confirm(_ target: Rect) -> Rect? {
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            repeat {
                if identityValid(), let observed = frame(window), matches(observed, target) { return observed }
                pause()
            } while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline
            return nil
        }
        // Feed a real pure-core placement into AX. Coordinates stay in the AX
        // domain: derive this small test canvas from the original AX frame.
        let canvas = Rect(x: original.x + 24, y: original.y + 24,
                          width: original.width + 40, height: original.height + 20)
        let layout = Layout(columns: [Column(slots: [Slot(id: "fixture", members: [wid], activeMember: wid)],
                                                   width: canvas.width)], focused: "fixture")
        guard let target = try? layout.placements(in: canvas, gap: 0).first?.frame else {
            report["reason"] = "Core layout rejected fixture canvas"; return report
        }
        report["windowID"] = wid
        report["original"] = json(original)
        report["requested"] = json(target)
        let writes = write(target)
        report["placementWriteErrors"] = writes
        let observed = confirm(target)
        report["placementConfirmed"] = observed != nil
        if let observed { report["observed"] = json(observed) }
        let restoration = write(original)
        report["restoreWriteErrors"] = restoration
        let restored = confirm(original)
        report["restoreConfirmed"] = restored != nil
        if let restored { report["restored"] = json(restored) }
        report["result"] = writes.count == 3 && writes.allSatisfy { $0 == 0 } && observed != nil &&
            restoration.count == 3 && restoration.allSatisfy { $0 == 0 } && restored != nil ? "passed" : "failed"
        report["reason"] = "Requires successful AX writes plus observed placement and restoration within 2-point tolerance"
        return report
    }
}
