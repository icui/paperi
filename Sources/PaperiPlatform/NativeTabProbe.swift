import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

extension Diagnostics {
    /// External discovery → membership → shared session → AX effects. The only
    /// writable process is the disposable child launched inside this function.
    @MainActor public static func probeNativeTabSession(reconcileTopology: Bool = false, admitNewMembers: Bool = false) -> [String: Any] {
        precondition(!admitNewMembers || reconcileTopology)
        var report: [String: Any] = ["schemaVersion": 1, "result": "failed",
            "scope": "Disposable AppKit native-tab child only; stop on topology/evidence loss"]
        guard AXIsProcessTrusted() else { report["reason"] = "Accessibility trust required"; return report }
        let child = Process()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperi-native-session-\(UUID())")
        defer {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { report["reason"] = "Cannot create fixture directory"; return report }
        let log = directory.appendingPathComponent("fixture.jsonl")
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("PaperiAXFixture")
        child.arguments = [log.path, "--tab-session"] + (reconcileTopology ? ["--tab-reconcile"] : [])
        if admitNewMembers { child.arguments!.append("--tab-growth") }
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { report["reason"] = "Build all products first"; return report }
        let pid = child.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var destroyed: Set<UInt32> = []
        var created: Set<UInt32> = []
        let recorder = EventRecorder(workspaceCenter: NotificationCenter(), runningApplications: {
            NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
        }, observeWorkspaceEvents: false, emit: { row in
            if row["event"] as? String == "AXUIElementDestroyed", let id = row["windowID"] as? UInt32, id > 0 {
                destroyed.insert(id)
            }
            if row["event"] as? String == "AXWindowCreated", let id = row["windowID"] as? UInt32, id > 0 {
                created.insert(id)
            }
        })
        recorder.start()
        defer { recorder.stop() }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let canvas = Rect(x: bounds.minX + 60, y: bounds.minY + 100,
            width: min(900, bounds.width - 120), height: min(360, bounds.height - 180))
        let session = ScopedLayoutSession(ownerPID: pid, canvas: canvas)
        let ticket = session.ticket
        var refs: [UInt32: AXUIElement] = [:]
        var originals: [UInt32: Rect] = [:]
        var last: NativeTabMembership?
        var memberSpaces = NativeTabMemberSpaces()
        var timeline: [[String: Any]] = []
        var failures: [String] = []
        var evidenceTimeline: [[String: Any]] = []
        var admissionRejections: [[String: Any]] = []
        var stoppedOnLoss = false
        var restored: [String: Bool] = [:]
        var topologyTimeline: [[String: Any]] = []
        var withheld = 0
        var lastPolicy: Classification?
        func pause() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        func space(_ id: UInt32) -> UInt64? {
            guard let values = paperi_copy_window_spaces(id) as? [NSNumber], values.count == 1 else { return nil }
            return values[0].uint64Value
        }
        func valid(_ ref: AXUIElement, _ id: UInt32) -> Bool {
            var owner: pid_t = 0
            return child.isRunning && AXUIElementGetPid(ref, &owner) == .success && owner == pid &&
                paperi_window_id(ref) == id && attribute(ref, kAXRoleAttribute) as? String == "AXWindow"
        }
        func classification(_ ref: AXUIElement, _ id: UInt32) -> Classification {
            var move = DarwinBoolean(false), size = DarwinBoolean(false)
            let m = AXUIElementIsAttributeSettable(ref, kAXPositionAttribute as CFString, &move)
            let s = AXUIElementIsAttributeSettable(ref, kAXSizeAttribute as CFString, &size)
            let parent = attribute(ref, kAXParentAttribute)
            let level = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?
                .first?[kCGWindowLayer as String] as? Int
            return WindowPolicy.classify(WindowFacts(bundleID: "disposable-child",
                role: attribute(ref, kAXRoleAttribute) as? String, subrole: attribute(ref, kAXSubroleAttribute) as? String,
                isRoot: parent.map { CFEqual($0, application) }, movable: m == .success ? move.boolValue : nil,
                resizable: s == .success ? size.boolValue : nil,
                fullscreen: attribute(ref, "AXFullScreen") as? Bool,
                minimized: attribute(ref, kAXMinimizedAttribute) as? Bool, level: level))
        }
        func matches(_ a: Rect, _ b: Rect) -> Bool {
            zip([a.x, a.y, a.width, a.height], [b.x, b.y, b.width, b.height]).allSatisfy { abs($0 - $1) <= 2 }
        }
        func write(_ id: UInt32, _ target: Rect, _ expectedSpace: UInt64, selectedOnly: Bool = false) -> Bool {
            guard let ref = refs[id], target.isValid else { return false }
            var point = CGPoint(x: target.x, y: target.y), size = CGSize(width: target.width, height: target.height)
            guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return false }
            for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)] {
                if selectedOnly {
                    guard session.accepts(ticket),
                          (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).contains(where: { paperi_window_id($0) == id }) else { return false }
                }
                guard valid(ref, id), space(id) == expectedSpace, classification(ref, id).eligibility == .tiled,
                      AXUIElementSetAttributeValue(ref, name as CFString, value) == .success else { return false }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            repeat {
                if valid(ref, id), let observed = frame(ref), matches(observed, target) { return true }
                pause()
            } while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline
            return false
        }
        func stopAndRestore() {
            let expectedSpace = session.spaceID
            session.stop()
            if let expectedSpace {
                for (id, original) in originals { restored[String(id)] = write(id, original, expectedSpace) }
            }
        }
        defer { if session.running { stopAndRestore() } }
        // The child's script starts after AppKit launch, not Process.run().
        // Bound startup plus the 49-second growth sequence independently of AX
        // correctness; a slow GUI launch must not cut off the closure stages.
        let deadline = ProcessInfo.processInfo.systemUptime + (admitNewMembers ? 75 : (reconcileTopology ? 31 : 25))
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            recorder.reconcileNow()
            for id in destroyed { originals.removeValue(forKey: id) }
            for ref in attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                let id = paperi_window_id(ref)
                AXUIElementSetMessagingTimeout(ref, 0.15)
                if id > 0, valid(ref, id) {
                    refs[id] = ref
                    // Save before management; never overwrite with tiled geometry.
                    if !destroyed.contains(id), originals[id] == nil, last == nil || (created.contains(id) && session.slots[id] == nil) {
                        originals[id] = frame(ref)
                    }
                }
            }
            if session.running {
                let evidence = recorder.tabEvidence(processID: pid)
                let app = (evidence["applications"] as? [[String: Any]])?.first
                let candidates = app.map(NativeTabMembership.inspect) ?? []
                if let app {
                    if let nodes = app["nodes"] as? [[String: Any]], let roots = app["roots"] as? [Int],
                       let observed = app["observedRoots"] as? [Int], let scope = app["identityScope"] as? String {
                        let capture = TabSelectionEvidence.inspect(nodes: nodes, roots: roots + observed,
                            complete: app["truncated"] as? Bool == false && app["identityTruncated"] as? Bool == false)
                        for group in capture.groups ?? [] where group.selected != nil {
                            if let ref = refs[group.window], valid(ref, group.window),
                               classification(ref, group.window).eligibility == .tiled, let sid = space(group.window) {
                                memberSpaces.observe(scope: scope, group: group.group, selected: group.window, space: sid)
                            }
                        }
                    }
                    evidenceTimeline.append(["uptime": ProcessInfo.processInfo.systemUptime,
                        "evidence": app.filter { ["rootValidations", "identityScope", "selectionAssociations",
                            "truncated", "truncationReasons", "windowCoverage"].contains($0.key) },
                        "confirmedGroupCount": candidates.count])
                }
                if reconcileTopology, last != nil {
                    if let app, let sid = session.spaceID, let policy = lastPolicy,
                       let partitions = NativeTabTopology.inspect(app, managed: Set(session.slots.keys), destroyed: destroyed,
                            additions: admitNewMembers ? created.subtracting(destroyed) : []) {
                        let checked = partitions.allSatisfy { partition in
                            guard let ref = refs[partition.active], valid(ref, partition.active), space(partition.active) == sid,
                                  classification(ref, partition.active).eligibility == .tiled,
                                  partition.members.allSatisfy({ id in refs[id].map { valid($0, id) } == true }) else { return false }
                            if partition.members.count == 1 { return true }
                            guard let candidate = candidates.first(where: { $0.members == partition.members && $0.active == partition.active }) else { return false }
                            let spaces = Dictionary(uniqueKeysWithValues: partition.members.compactMap { id in space(id).map { (id, $0) } })
                            return memberSpaces.confirmedSpace(for: candidate, current: spaces) == sid
                        }
                        if checked {
                            do {
                                let changed = try session.reconcileTabs(partitions, destroyed: destroyed, ownerPID: pid,
                                    spaceID: sid, classification: policy, ticket: ticket,
                                    admitted: Set(partitions.flatMap(\.members)).subtracting(session.slots.keys))
                                if changed {
                                    let placements = try session.state.layout.placements(in: canvas)
                                    var confirmed = true
                                    for placement in placements {
                                        if let ref = refs[placement.windowID], let observed = frame(ref), matches(observed, placement.frame) { continue }
                                        confirmed = write(placement.windowID, placement.frame, sid, selectedOnly: true) && confirmed
                                    }
                                    confirmed = confirmed && placements.allSatisfy { placement in
                                        guard let ref = refs[placement.windowID], valid(ref, placement.windowID),
                                              let observed = frame(ref) else { return false }
                                        return matches(observed, placement.frame)
                                    }
                                    topologyTimeline.append(["uptime": ProcessInfo.processInfo.systemUptime,
                                        "partitions": partitions.map { p -> [String: Any] in
                                            ["members": p.members, "active": p.active, "slot": session.slots[p.active] ?? ""]
                                        }, "confirmed": confirmed, "columns": session.state.layout.columns.count,
                                        "slots": session.state.layout.columns.map { $0.slots[0].id }])
                                    if !confirmed { failures.append("Topology placement not confirmed"); stopAndRestore() }
                                }
                            } catch { failures.append("Topology rejected: \(error)"); stopAndRestore() }
                        } else { withheld += 1 }
                    } else { withheld += 1 }
                } else {
                let candidate = candidates.first { last == nil || ($0.scope == last!.scope && $0.group == last!.group && $0.members == last!.members) }
                if let candidate, candidate != last {
                    let spaces = Dictionary(uniqueKeysWithValues: candidate.members.compactMap { id in space(id).map { (id, $0) } })
                    let confirmedSpace = memberSpaces.confirmedSpace(for: candidate, current: spaces)
                    let checked = candidate.members.allSatisfy { id in
                        guard let ref = refs[id] else { return false }
                        return valid(ref, id)
                    }
                    if !checked || confirmedSpace == nil {
                        admissionRejections.append(["members": candidate.members.map { id -> [String: Any] in
                            guard let ref = refs[id] else { return ["id": id, "reason": "missingReference"] }
                            return ["id": id, "valid": valid(ref, id), "space": space(id) ?? 0,
                                    "policy": classification(ref, id).reason]
                        }])
                    }
                    if checked, let sid = confirmedSpace, let ref = refs[candidate.active],
                       classification(ref, candidate.active).eligibility == .tiled {
                        do {
                            if let previous = last {
                                try session.confirmTabs(anchor: previous.active, members: candidate.members, active: candidate.active,
                                    ownerPID: pid, spaceID: sid, classification: classification(ref, candidate.active), ticket: ticket)
                                // A width command proves writes target the newly selected representative.
                                try session.resize(windowID: candidate.active, ownerPID: pid, spaceID: sid,
                                    width: session.state.layout.columns[0].width + 40,
                                    classification: classification(ref, candidate.active), ticket: ticket)
                            } else {
                                try session.admitTabs(members: candidate.members, active: candidate.active, ownerPID: pid,
                                    spaceID: sid, classification: classification(ref, candidate.active), ticket: ticket)
                            }
                            guard let placement = try session.state.layout.placements(in: canvas).first else {
                                failures.append("No placement after admission"); stopAndRestore(); continue
                            }
                            let confirmed = write(placement.windowID, placement.frame, sid, selectedOnly: true)
                            timeline.append(["uptime": ProcessInfo.processInfo.systemUptime, "active": candidate.active,
                                "members": candidate.members, "slot": session.slots[candidate.active] ?? "",
                                "width": session.state.layout.columns[0].width, "writtenWindow": placement.windowID,
                                "confirmed": confirmed])
                            last = candidate
                            lastPolicy = classification(ref, candidate.active)
                            if !confirmed { failures.append("AX placement not confirmed"); stopAndRestore() }
                        } catch { failures.append("Session rejected membership: \(error)"); stopAndRestore() }
                    } else if last != nil { failures.append("Member validation lost"); stopAndRestore() }
                } else if candidate == nil, last != nil {
                    stoppedOnLoss = true; stopAndRestore()
                }
                }
            }
            let sampleEnd = ProcessInfo.processInfo.systemUptime + 0.25
            while child.isRunning && ProcessInfo.processInfo.systemUptime < sampleEnd { pause() }
        }
        // Closing the final NSWindow can block AppKit until the termination
        // timer is due. Drain queued native destruction and apply its proof
        // without reading dead AX references or performing geometry writes.
        if !child.isRunning { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) }
        for id in destroyed { originals.removeValue(forKey: id) }
        if reconcileTopology, session.running, !session.slots.isEmpty,
           Set(session.slots.keys).isSubset(of: destroyed), let sid = session.spaceID, let policy = lastPolicy {
            do {
                try session.reconcileTabs([], destroyed: destroyed, ownerPID: pid, spaceID: sid,
                    classification: policy, ticket: ticket)
                topologyTimeline.append(["uptime": ProcessInfo.processInfo.systemUptime,
                    "partitions": [[String: Any]](), "confirmed": true, "columns": 0, "slots": [String]()])
            } catch { failures.append("Final destruction rejected: \(error)") }
        }
        let emptyBeforeStop = session.slots.isEmpty && session.state.layout.columns.isEmpty
        if session.running { stopAndRestore() }
        // Ground truth is read only after all management/effects have stopped.
        let truth = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let selected = timeline.compactMap { entry -> UInt32? in
            guard let time = entry["uptime"] as? Double,
                  let stage = truth.last(where: { ($0["uptime"] as? Double ?? .infinity) <= time }),
                  let windows = stage["tabWindows"] as? [[String: Any]] else { return nil }
            return windows.first?["selected"] as? UInt32
        }
        let active = timeline.compactMap { $0["active"] as? UInt32 }
        var checks: [String: Bool] = ["twoRepresentativesManaged": active.count >= 2 && Set(active).count == 2,
            "matchesNativeSelection": !active.isEmpty && active == selected,
            "stableLogicalSlot": !timeline.isEmpty && Set(timeline.compactMap { $0["slot"] as? String }).count == 1,
            "onlySelectedRepresentativeWritten": !timeline.isEmpty && timeline.allSatisfy { $0["active"] as? UInt32 == $0["writtenWindow"] as? UInt32 },
            "allPlacementsConfirmed": !timeline.isEmpty && timeline.allSatisfy { $0["confirmed"] as? Bool == true },
            "stoppedOnEvidenceOrTopologyLoss": stoppedOnLoss,
            "restoredBothPhysicalWindows": restored.count == 2 && restored.values.allSatisfy { $0 },
            "fixtureCompleted": truth.contains { $0["event"] as? String == "terminating" },
            "managementRevoked": !session.running]
        if reconcileTopology {
            // Compare external partitions to the latest completed native action.
            checks["twoRepresentativesManaged"] = nil
            checks["stoppedOnEvidenceOrTopologyLoss"] = nil
            checks["restoredBothPhysicalWindows"] = nil
            checks["nativeTopologyMatches"] = !topologyTimeline.isEmpty && topologyTimeline.allSatisfy { entry in
                guard let time = entry["uptime"] as? Double,
                      let stage = truth.last(where: { ($0["uptime"] as? Double ?? .infinity) <= time }),
                      let windows = stage["tabWindows"] as? [[String: Any]],
                      let partitions = entry["partitions"] as? [[String: Any]] else { return false }
                let expected = Set(windows.filter { $0["visible"] as? Bool == true }.map { window in
                    let members = window["members"] as? [UInt32] ?? []
                    let id = window["id"] as! UInt32
                    let active = window["selected"] as? UInt32 ?? 0
                    return (members.isEmpty ? [id] : members).sorted().map(String.init).joined(separator: ",") + ":\(active > 0 ? active : id)"
                })
                let actual = Set(partitions.map { ($0["members"] as! [UInt32]).sorted().map(String.init).joined(separator: ",") + ":\($0["active"] as! UInt32)" })
                return expected == actual
            }
            checks["detachReconciled"] = topologyTimeline.contains { $0["columns"] as? Int == 2 }
            let detachIndex = topologyTimeline.firstIndex { $0["columns"] as? Int == 2 }
            checks["mergeReconciled"] = topologyTimeline.enumerated().contains { index, entry in
                let parts = entry["partitions"] as? [[String: Any]] ?? []
                return detachIndex.map { index > $0 } == true && parts.count == 1 && (parts[0]["members"] as? [UInt32])?.count == 2
            }
            checks["activeClosurePreservedSlot"] = topologyTimeline.enumerated().contains { index, entry in
                let parts = entry["partitions"] as? [[String: Any]] ?? []
                guard index > 0, parts.count == 1, (parts[0]["members"] as? [UInt32])?.count == 1,
                      let previous = topologyTimeline[index - 1]["partitions"] as? [[String: Any]],
                      previous.count == 1, (previous[0]["members"] as? [UInt32])?.count == 2 else { return false }
                return parts[0]["slot"] as? String == previous[0]["slot"] as? String
            }
            checks["lastClosureEmptiedSession"] = emptyBeforeStop && destroyed.count == (admitNewMembers ? 3 : 2)
            checks["topologyPlacementsConfirmed"] = topologyTimeline.allSatisfy { $0["confirmed"] as? Bool == true }
            checks["closedRecoveryEntriesRemoved"] = originals.isEmpty
            checks["incompleteTopologyWithheld"] = withheld > 0
            report["scope"] = "Disposable AppKit child; continued native topology reconciliation"
            if admitNewMembers {
                let growthIndex = topologyTimeline.firstIndex { entry in
                    (entry["partitions"] as? [[String: Any]] ?? []).contains { ($0["members"] as? [UInt32])?.count == 3 }
                }
                checks["newMemberAdmitted"] = growthIndex != nil
                checks["growthRetainedSlot"] = growthIndex.map { index in
                    guard index > 0, let prior = topologyTimeline[index - 1]["slots"] as? [String],
                          let after = topologyTimeline[index]["slots"] as? [String] else { return false }
                    return prior == after
                } ?? false
                let originalMembers = Set(timeline.first?["members"] as? [UInt32] ?? [])
                checks["newMemberSelectedManaged"] = topologyTimeline.contains { entry in
                    (entry["partitions"] as? [[String: Any]] ?? []).contains { part in
                        guard let active = part["active"] as? UInt32, let members = part["members"] as? [UInt32] else { return false }
                        return members.count == 3 && !originalMembers.contains(active) && created.contains(active)
                    }
                }
                report["scope"] = "Disposable AppKit child; guarded native member creation and lifecycle"
            }
        }
        report["fixturePID"] = pid; report["checks"] = checks; report["timeline"] = timeline
        report["evidenceTimeline"] = evidenceTimeline
        report["admissionRejections"] = admissionRejections
        report["restored"] = restored; report["failures"] = failures
        report["topologyTimeline"] = topologyTimeline; report["withheldSamples"] = withheld
        report["createdWindowIDs"] = created.sorted(); report["destroyedWindowIDs"] = destroyed.sorted()
        report["fixtureActions"] = truth.map { $0.filter { ["event", "uptime"].contains($0.key) } }
        report["result"] = checks.values.allSatisfy { $0 } && failures.isEmpty ? "passed" : "failed"
        return report
    }
}
