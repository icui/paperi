import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

extension Diagnostics {
    /// Explicit opt-in for a freshly tagged Terminal test representative. The
    /// harness creates the UUID tag; existing untagged windows cannot pass.
    @MainActor public static func probeTerminalPlacement(windowID: UInt32, tag: String, resize: Bool = false) -> [String: Any] {
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
        guard sid > 0 else { report["reason"] = "Invalid Space identity"; return report }
        report["spaceID"] = sid
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
            if resize {
                var size = CGSize(width: target.width, height: target.height)
                guard target.isValid, let value = AXValueCreate(.cgSize, &size), valid() else { return [] }
                return [AXUIElementSetAttributeValue(ref, kAXSizeAttribute as CFString, value).rawValue]
            }
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
        var cellWidth = 0.0
        var originalColumns: Int?
        func columns(_ target: Int? = nil) -> Int? {
            guard valid() else { return nil }
            let assignment = target.map { "set number of columns of selected tab of window id \(windowID) to \($0)" } ?? ""
            let source = """
            with timeout of 2 seconds
            tell application id "com.apple.Terminal"
              if id of front window is not \(windowID) then return 0
              if custom title of selected tab of front window is not "\(tag)" then return 0
              \(assignment)
              return number of columns of selected tab of window id \(windowID)
            end tell
            end timeout
            """
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return nil }
            let value = script.executeAndReturnError(&error)
            return error == nil && value.int32Value > 0 ? Int(value.int32Value) : nil
        }
        if resize {
            report["scope"] = "Exact tagged Terminal representative; measured cell-grid width resize/recovery"
            guard let count = columns(), count < 500 else { report["reason"] = "Grid metadata unavailable"; return report }
            originalColumns = count
            let calibrated = columns(count + 1) == count + 1
            let sample = frame(ref)
            let columnsRestored = columns(count) == count
            let frameRestored = confirm(original)
            report["originalColumns"] = count
            report["calibrationRestored"] = columnsRestored && frameRestored
            guard calibrated, let sample, columnsRestored, frameRestored else {
                report["reason"] = "Cell calibration or restoration failed"; return report
            }
            cellWidth = sample.width - original.width
            guard cellWidth.isFinite, cellWidth > 0, cellWidth < 100,
                  abs(sample.height - original.height) <= 2 else {
                report["reason"] = "Invalid measured cell geometry"; return report
            }
            report["cellWidth"] = cellWidth
            report["requestedColumns"] = count + 4
        }
        let canvas = resize ? Rect(x: original.x, y: original.y, width: original.width + cellWidth * 4, height: original.height) :
            Rect(x: original.x + 24, y: original.y + 24, width: original.width, height: original.height)
        let layout = Layout(columns: [Column(slots: [Slot(id: "terminal-test", members: [windowID], activeMember: windowID)], width: canvas.width)])
        guard let target = try? layout.placements(in: canvas, gap: 0).first?.frame, valid() else {
            report["reason"] = "Policy/ownership rejected placement"; return report
        }
        report["original"] = json(original); report["target"] = json(target)
        let writes = write(target)
        let placed = confirm(target)
        let observedColumns = resize ? columns() : nil
        // Always attempt guarded recovery, even after a partial/failed write.
        let restoration = write(original)
        let restored = confirm(original)
        let restoredColumns = resize ? columns() : nil
        let gridConfirmed: Bool
        if resize, let expected = originalColumns {
            gridConfirmed = observedColumns == expected + 4 && restoredColumns == expected
        } else { gridConfirmed = !resize }
        if resize {
            if let observedColumns { report["observedColumns"] = observedColumns }
            if let restoredColumns { report["restoredColumns"] = restoredColumns }
            report["gridColumnsConfirmed"] = gridConfirmed
        }
        report["placementWriteErrors"] = writes; report["restoreWriteErrors"] = restoration
        report["placementConfirmed"] = placed; report["restoreConfirmed"] = restored
        report["result"] = writes.count == 1 && writes.allSatisfy { $0 == 0 } && placed &&
            restoration.count == 1 && restoration.allSatisfy { $0 == 0 } && restored && gridConfirmed ? "passed" : "failed"
        return report
    }

    /// Sustained shared-session Terminal probe. The caller drives selection,
    /// new-tab creation and active/last closure on newly created UUID-tagged
    /// tabs, while this loop learns membership externally through AX and drives
    /// `ScopedLayoutSession` placements and topology reconciliation.
    @MainActor public static func probeTerminalSession(tag: String) -> [String: Any] {
        var report: [String: Any] = ["schemaVersion": 1, "result": "failed",
            "scope": "Sustained shared-session Terminal native-tab lifecycle; UUID-tagged idle test tabs only"]
        let prefix = "Paperi-test-"
        guard tag.hasPrefix(prefix), tag.count == prefix.count + 36,
              UUID(uuidString: String(tag.dropFirst(prefix.count))) != nil,
              AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first else {
            report["reason"] = "Invalid test tag or unavailable Terminal/Accessibility"; return report
        }
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var destroyed: Set<UInt32> = [], created: Set<UInt32> = []
        let recorder = EventRecorder(workspaceCenter: NotificationCenter(), runningApplications: {
            NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
        }, observeWorkspaceEvents: false, emit: { row in
            if row["event"] as? String == "AXUIElementDestroyed", let id = row["windowID"] as? UInt32, id > 0 { destroyed.insert(id) }
            if row["event"] as? String == "AXWindowCreated", let id = row["windowID"] as? UInt32, id > 0 { created.insert(id) }
        })
        recorder.start()
        defer { recorder.stop() }
        func space(_ id: UInt32) -> UInt64? {
            guard let values = paperi_copy_window_spaces(id) as? [NSNumber], values.count == 1 else { return nil }
            return values[0].uint64Value
        }
        func owned(_ id: UInt32) -> Bool {
            guard id > 0, !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            let source = """
            with timeout of 2 seconds
            tell application id "com.apple.Terminal"
              if not (exists window id \(id)) then return false
              if id of front window is not \(id) then return false
              set w to front window
              if custom title of selected tab of w is not "\(tag)" then return false
              repeat with t in tabs of w
                if custom title of t is not "\(tag)" then return false
                if busy of t then return false
              end repeat
              return true
            end tell
            end timeout
            """
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return false }
            let value = script.executeAndReturnError(&error)
            return error == nil && value.booleanValue
        }
        func valid(_ ref: AXUIElement, _ id: UInt32) -> Bool {
            var owner: pid_t = 0
            return !app.isTerminated && AXUIElementGetPid(ref, &owner) == .success && owner == pid &&
                paperi_window_id(ref) == id && attribute(ref, kAXRoleAttribute) as? String == "AXWindow"
        }
        func classification(_ ref: AXUIElement, _ id: UInt32) -> Classification {
            var move = DarwinBoolean(false), size = DarwinBoolean(false)
            let m = AXUIElementIsAttributeSettable(ref, kAXPositionAttribute as CFString, &move)
            let s = AXUIElementIsAttributeSettable(ref, kAXSizeAttribute as CFString, &size)
            let parent = attribute(ref, kAXParentAttribute)
            let level = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?
                .first?[kCGWindowLayer as String] as? Int
            return WindowPolicy.classify(WindowFacts(bundleID: "com.apple.Terminal",
                role: attribute(ref, kAXRoleAttribute) as? String, subrole: attribute(ref, kAXSubroleAttribute) as? String,
                isRoot: parent.map { CFEqual($0, application) }, movable: m == .success ? move.boolValue : nil,
                resizable: s == .success ? size.boolValue : nil,
                fullscreen: attribute(ref, "AXFullScreen") as? Bool,
                minimized: attribute(ref, kAXMinimizedAttribute) as? Bool, level: level))
        }
        func matchesPosition(_ a: Rect, _ b: Rect) -> Bool {
            abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2
        }
        var refs: [UInt32: AXUIElement] = [:]
        var recovery = FrameRestorationJournal()
        var session: ScopedLayoutSession?
        var ticket = UUID()
        var memberSpaces = NativeTabMemberSpaces()
        var lastPolicy: Classification?
        var timeline: [[String: Any]] = []
        var topologyTimeline: [[String: Any]] = []
        var failures: [String] = []
        var withheld = 0
        var knownOwned: Set<UInt32> = []
        func writePosition(_ id: UInt32, _ target: Rect, _ expectedSpace: UInt64) -> Bool {
            guard let ref = refs[id], target.isValid, owned(id), valid(ref, id),
                  space(id) == expectedSpace, classification(ref, id).eligibility == .tiled else { return false }
            var point = CGPoint(x: target.x, y: target.y)
            guard let value = AXValueCreate(.cgPoint, &point),
                  AXUIElementSetAttributeValue(ref, kAXPositionAttribute as CFString, value) == .success else { return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.2
            repeat {
                if valid(ref, id), let observed = frame(ref), matchesPosition(observed, target) { return true }
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            } while ProcessInfo.processInfo.systemUptime < deadline
            return false
        }
        var stoppedReport: [String: Any]?
        func stopSession() -> [String: Any] {
            if let stoppedReport { return stoppedReport }
            let expectedSpace = session?.spaceID
            session?.stop()
            let teardown = recorder.stop()
            let restored = recovery.restore(managementStopped: session?.running != true) { id, original in
                guard let expectedSpace, let ref = refs[id], valid(ref, id) else { return false }
                if let current = frame(ref), matchesPosition(current, original) { return true }
                return writePosition(id, original, expectedSpace)
            } ?? [:]
            let result: [String: Any] = ["teardown": teardown,
                "restored": Dictionary(uniqueKeysWithValues: restored.map { (String($0.key), $0.value) }),
                "allRestored": restored.values.allSatisfy { $0 }]
            stoppedReport = result
            return result
        }
        defer { _ = stopSession() }
        printJSON(["event": "terminalSessionReady", "pid": pid, "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
        let deadline = ProcessInfo.processInfo.systemUptime + 65
        while !app.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
            recorder.reconcileNow()
            for id in destroyed { recovery.remove(windowID: id) }
            for ref in attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                let id = paperi_window_id(ref)
                AXUIElementSetMessagingTimeout(ref, 0.15)
                if id > 0, valid(ref, id) { refs[id] = ref }
            }
            let evidence = recorder.tabEvidence(processID: pid)
            let appReport = (evidence["applications"] as? [[String: Any]])?.first
            let candidates = appReport.map(NativeTabMembership.inspect) ?? []
            if let appReport, let nodes = appReport["nodes"] as? [[String: Any]],
               let roots = appReport["roots"] as? [Int], let observed = appReport["observedRoots"] as? [Int],
               let scope = appReport["identityScope"] as? String {
                let capture = TabSelectionEvidence.inspect(nodes: nodes, roots: roots + observed,
                    complete: appReport["truncated"] as? Bool == false && appReport["identityTruncated"] as? Bool == false)
                for group in capture.groups ?? [] where group.selected != nil {
                    if let ref = refs[group.window], valid(ref, group.window), owned(group.window),
                       classification(ref, group.window).eligibility == .tiled, let sid = space(group.window) {
                        knownOwned.insert(group.window)
                        if let current = frame(ref), current.isValid { recovery.remember(windowID: group.window, frame: current) }
                        memberSpaces.observe(scope: scope, group: group.group, selected: group.window, space: sid)
                    }
                }
            }
            if session == nil {
                if let candidate = candidates.first(where: { Set($0.members).isSubset(of: knownOwned) && owned($0.active) }),
                   let activeRef = refs[candidate.active], let original = frame(activeRef), original.isValid {
                    let spaces = Dictionary(uniqueKeysWithValues: candidate.members.compactMap { id in space(id).map { (id, $0) } })
                    let policy = classification(activeRef, candidate.active)
                    if let sid = memberSpaces.confirmedSpace(for: candidate, current: spaces),
                       policy.eligibility == .tiled,
                       candidate.members.allSatisfy({ id in refs[id].map { valid($0, id) } == true }) {
                        let canvas = Rect(x: original.x + 24, y: original.y + 24, width: original.width * 2 + 8, height: original.height)
                        let createdSession = ScopedLayoutSession(ownerPID: pid, canvas: canvas)
                        let createdTicket = createdSession.ticket
                        do {
                            try createdSession.admitTabs(members: candidate.members, active: candidate.active,
                                ownerPID: pid, spaceID: sid, classification: policy, ticket: createdTicket)
                            guard let placement = try createdSession.state.layout.placements(in: canvas, gap: 0).first else {
                                failures.append("No placement after admission"); break
                            }
                            let confirmed = writePosition(placement.windowID, placement.frame, sid)
                            session = createdSession; ticket = createdTicket; lastPolicy = policy
                            let entry: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime,
                                "active": candidate.active, "members": candidate.members,
                                "slot": createdSession.slots[candidate.active] ?? "",
                                "writtenWindow": placement.windowID, "confirmed": confirmed]
                            timeline.append(entry)
                            printJSON(["event": "terminalSessionAdmitted", "entry": entry], pretty: false)
                            if !confirmed { failures.append("Initial placement unconfirmed"); break }
                        } catch { failures.append("Session rejected admission: \(error)"); break }
                    }
                }
            } else if let activeSession = session, activeSession.running, let sid = activeSession.spaceID, let policy = lastPolicy {
                let additions = created.intersection(knownOwned).subtracting(destroyed)
                if let appReport,
                   let partitions = NativeTabTopology.inspect(appReport, managed: Set(activeSession.slots.keys),
                                                              destroyed: destroyed, additions: additions) {
                    if partitions.isEmpty {
                        do {
                            try activeSession.reconcileTabs([], destroyed: destroyed, ownerPID: pid, spaceID: sid,
                                                            classification: policy, ticket: ticket)
                            topologyTimeline.append(["uptime": ProcessInfo.processInfo.systemUptime,
                                "partitions": [[String: Any]](), "confirmed": true, "columns": 0, "slots": [String]()])
                            printJSON(["event": "terminalSessionEmptied", "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
                            break
                        } catch { failures.append("Empty reconciliation rejected: \(error)"); break }
                    }
                    let checked = partitions.allSatisfy { partition in
                        guard owned(partition.active), let ref = refs[partition.active], valid(ref, partition.active),
                              space(partition.active) == sid, classification(ref, partition.active).eligibility == .tiled,
                              partition.members.allSatisfy({ id in knownOwned.contains(id) && refs[id].map { valid($0, id) } == true }) else { return false }
                        if partition.members.count == 1 { return true }
                        guard let candidate = candidates.first(where: { $0.members == partition.members && $0.active == partition.active }) else { return false }
                        let spaces = Dictionary(uniqueKeysWithValues: partition.members.compactMap { id in space(id).map { (id, $0) } })
                        return memberSpaces.confirmedSpace(for: candidate, current: spaces) == sid
                    }
                    if checked {
                        do {
                            let admitted = Set(partitions.flatMap(\.members)).subtracting(activeSession.slots.keys)
                            let changed = try activeSession.reconcileTabs(partitions, destroyed: destroyed, ownerPID: pid,
                                spaceID: sid, classification: policy, ticket: ticket, admitted: admitted)
                            if changed {
                                let placements = try activeSession.state.layout.placements(in: activeSession.canvas, gap: 0)
                                var confirmed = true
                                for placement in placements {
                                    if let ref = refs[placement.windowID], let current = frame(ref), matchesPosition(current, placement.frame) { continue }
                                    confirmed = writePosition(placement.windowID, placement.frame, sid) && confirmed
                                }
                                let entry: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime,
                                    "partitions": partitions.map { p -> [String: Any] in
                                        ["members": p.members, "active": p.active, "slot": activeSession.slots[p.active] ?? ""]
                                    }, "confirmed": confirmed, "columns": activeSession.state.layout.columns.count,
                                    "slots": activeSession.state.layout.columns.map { $0.slots[0].id }]
                                topologyTimeline.append(entry)
                                if partitions.count == 1, let part = partitions.first {
                                    timeline.append(["uptime": ProcessInfo.processInfo.systemUptime, "active": part.active,
                                        "members": part.members, "slot": activeSession.slots[part.active] ?? "",
                                        "writtenWindow": part.active, "confirmed": confirmed])
                                }
                                printJSON(["event": "terminalSessionReconciled", "entry": entry], pretty: false)
                                if !confirmed { failures.append("Reconciled placement unconfirmed"); break }
                            }
                        } catch { failures.append("Reconciliation rejected: \(error)"); break }
                    } else { withheld += 1 }
                } else { withheld += 1 }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        let emptyBeforeStop = session.map { $0.slots.isEmpty && $0.state.layout.columns.isEmpty } ?? false
        let stopped = stopSession()
        let active = timeline.compactMap { $0["active"] as? UInt32 }
        let slots = Set(timeline.compactMap { $0["slot"] as? String })
        let growthIndex = topologyTimeline.firstIndex { entry in
            (entry["partitions"] as? [[String: Any]] ?? []).contains { ($0["members"] as? [UInt32])?.count == 3 }
        }
        let checks: [String: Bool] = [
            "admittedInitialPair": !timeline.isEmpty && (timeline.first?["members"] as? [UInt32])?.count == 2,
            "switchedRepresentativesInOneSlot": Set(active).count >= 2 && slots.count == 1,
            "newMemberAdmitted": growthIndex != nil,
            "growthPreservedLogicalSlot": growthIndex.map { idx in
                (topologyTimeline[idx]["slots"] as? [String])?.first == slots.first
            } ?? false,
            "activeClosurePreservedSlot": topologyTimeline.contains { entry in
                let parts = entry["partitions"] as? [[String: Any]] ?? []
                return parts.count == 1 && (parts[0]["members"] as? [UInt32])?.count == 1 &&
                    parts[0]["slot"] as? String == slots.first
            },
            "lastClosureEmptiedSession": emptyBeforeStop,
            "incompleteTopologyWithheld": withheld > 0,
            "allPlacementsConfirmed": !timeline.isEmpty && timeline.allSatisfy { $0["confirmed"] as? Bool == true } &&
                topologyTimeline.allSatisfy { $0["confirmed"] as? Bool == true },
            "survivingFramesRestored": stopped["allRestored"] as? Bool == true,
            "nativeSourcesRemoved": (stopped["teardown"] as? [String: Any])?["sourcesStillInstalled"] as? Int == 0,
            "managementRevoked": session?.running == false,
            "noFailures": failures.isEmpty
        ]
        report["checks"] = checks; report["timeline"] = timeline; report["topologyTimeline"] = topologyTimeline
        report["withheldSamples"] = withheld; report["createdWindowIDs"] = created.sorted()
        report["destroyedWindowIDs"] = destroyed.sorted(); report["stop"] = stopped; report["failures"] = failures
        report["result"] = checks.values.allSatisfy { $0 } ? "passed" : "failed"
        return report
    }
}
