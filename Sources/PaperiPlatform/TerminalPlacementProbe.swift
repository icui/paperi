import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

extension Diagnostics {
    /// Explicit opt-in for a freshly tagged Terminal test representative. The
    /// harness creates the UUID tag; existing untagged windows cannot pass.
    @MainActor public static func probeTerminalPlacement(windowID: UInt32, tag: String) -> [String: Any] {
        var report: [String: Any] = ["result": "failed", "windowID": windowID,
            "scope": "Exact tagged frontmost Terminal representative; translation and restoration only"]
        let prefix = "Paperi-test-"
        guard windowID > 0, tag.hasPrefix(prefix), tag.count == prefix.count + 36,
              UUID(uuidString: String(tag.dropFirst(prefix.count))) != nil,
              AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            report["reason"] = "Invalid test identity or unavailable Terminal/Accessibility"; return report
        }
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        func owned() -> Bool {
            guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            // Validated UUID syntax makes these two interpolations data-only.
            let source = """
            with timeout of 2 seconds
            tell application id "com.apple.Terminal"
              if not (exists window id \(windowID)) then return false
              if id of front window is not \(windowID) then return false
              set t to selected tab of front window
              if custom title of t is not "\(tag)" then return false
              if busy of t then return false
              return true
            end tell
            end timeout
            """
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return false }
            let value = script.executeAndReturnError(&error)
            return error == nil && value.booleanValue
        }
        guard owned(), let ref = (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?
            .first(where: { paperi_window_id($0) == windowID }), let original = frame(ref), original.isValid,
              let spaces = paperi_copy_window_spaces(windowID) as? [NSNumber], spaces.count == 1 else {
            report["reason"] = "Owned selected reference/frame/Space unavailable"; return report
        }
        let sid = spaces[0].uint64Value
        AXUIElementSetMessagingTimeout(ref, 0.15)
        func valid() -> Bool {
            var owner: pid_t = 0
            guard owned(), AXUIElementGetPid(ref, &owner) == .success, owner == pid,
                  paperi_window_id(ref) == windowID,
                  let spaces = paperi_copy_window_spaces(windowID) as? [NSNumber], spaces.count == 1,
                  spaces[0].uint64Value == sid else { return false }
            var move = DarwinBoolean(false), size = DarwinBoolean(false)
            let m = AXUIElementIsAttributeSettable(ref, kAXPositionAttribute as CFString, &move)
            let s = AXUIElementIsAttributeSettable(ref, kAXSizeAttribute as CFString, &size)
            let parent = attribute(ref, kAXParentAttribute)
            let level = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?
                .first?[kCGWindowLayer as String] as? Int
            return WindowPolicy.classify(WindowFacts(bundleID: "com.apple.Terminal",
                role: attribute(ref, kAXRoleAttribute) as? String, subrole: attribute(ref, kAXSubroleAttribute) as? String,
                isRoot: parent.map { CFEqual($0, application) }, movable: m == .success ? move.boolValue : nil,
                resizable: s == .success ? size.boolValue : nil,
                fullscreen: attribute(ref, "AXFullScreen") as? Bool,
                minimized: attribute(ref, kAXMinimizedAttribute) as? Bool, level: level)).eligibility == .tiled
        }
        func matches(_ target: Rect) -> Bool {
            guard let observed = frame(ref) else { return false }
            return zip([observed.x, observed.y, observed.width, observed.height],
                       [target.x, target.y, target.width, target.height]).allSatisfy { abs($0 - $1) <= 2 }
        }
        func write(_ target: Rect) -> [Int32] {
            var point = CGPoint(x: target.x, y: target.y)
            guard target.isValid, let p = AXValueCreate(.cgPoint, &point), valid() else { return [] }
            // Dimensions are deliberately unchanged. Writing size here would
            // add an unrelated operation to this translation-only experiment.
            return [AXUIElementSetAttributeValue(ref, kAXPositionAttribute as CFString, p).rawValue]
        }
        func confirm(_ target: Rect) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            repeat {
                if valid(), matches(target) { return true }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            } while ProcessInfo.processInfo.systemUptime < deadline
            return false
        }
        func json(_ rect: Rect) -> [String: Double] {
            ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]
        }
        let canvas = Rect(x: original.x + 24, y: original.y + 24, width: original.width, height: original.height)
        let layout = Layout(columns: [Column(slots: [Slot(id: "terminal-test", members: [windowID], activeMember: windowID)], width: canvas.width)])
        guard let target = try? layout.placements(in: canvas, gap: 0).first?.frame, valid() else {
            report["reason"] = "Policy/ownership rejected placement"; return report
        }
        report["original"] = json(original); report["target"] = json(target)
        let writes = write(target)
        let placed = confirm(target)
        // Always attempt guarded recovery, even after a partial/failed write.
        let restoration = write(original)
        let restored = confirm(original)
        report["placementWriteErrors"] = writes; report["restoreWriteErrors"] = restoration
        report["placementConfirmed"] = placed; report["restoreConfirmed"] = restored
        report["result"] = writes.count == 1 && writes.allSatisfy { $0 == 0 } && placed &&
            restoration.count == 1 && restoration.allSatisfy { $0 == 0 } && restored ? "passed" : "failed"
        return report
    }
}
