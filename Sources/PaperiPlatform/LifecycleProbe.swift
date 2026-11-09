import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

extension Diagnostics {
    /// Native notification → pure reducer → confirmed AX effects, isolated to a
    /// freshly launched child. This is not the production management registry.
    @MainActor public static func probeLifecycle(externalResize: Bool = false, interaction: Bool = false,
                                                stopWhileOpen: Bool = false, preview: Bool = false,
                                                automatedPreview: Bool = false) -> [String: Any] {
        var report: [String: Any] = ["schemaVersion": 1, "result": "failed",
            "scope": "Two newly spawned non-tabbing fixture windows; no focus or Space writes"]
        guard AXIsProcessTrusted() else { report["reason"] = "Accessibility trust required"; return report }
        let child = Process()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperi-lifecycle-\(UUID())")
        defer {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { report["reason"] = "Cannot create fixture log directory"; return report }
        let log = directory.appendingPathComponent("fixture.jsonl")
        let previewToken = UUID().uuidString
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("PaperiAXFixture")
        child.arguments = [log.path, "--lifecycle-placement"] + (externalResize ? ["--external-resize"] : []) +
            (interaction ? ["--interaction"] : [])
        if preview {
            child.arguments! += ["--preview", "--preview-token", previewToken]
            if automatedPreview { child.arguments!.append("--preview-input-test") }
        }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { report["reason"] = "Build all products to supply sibling PaperiAXFixture"; return report }
        let pid = child.processIdentifier
        let started = ProcessInfo.processInfo.systemUptime
        report["fixturePID"] = pid
        var queued: [[String: Any]] = []
        let recorder = EventRecorder(workspaceCenter: NotificationCenter(), runningApplications: {
            NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
        }, observeWorkspaceEvents: false, emit: { queued.append($0) })
        recorder.start()
        defer { recorder.stop() }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var references: [UInt32: AXUIElement] = [:]
        var recovery = FrameRestorationJournal()
        var stoppedReport: [String: Any]?
        var restoreWriteCount = 0
        var created: [UInt32] = [], destroyed: [UInt32] = []
        var timeline: [[String: Any]] = []
        var failures: [String] = []
        var echoCount = 0
        var notificationCount = 0
        var adoptedWidths: [Double] = []
        var focusTimeline: [[String: Any]] = []
        var commandTimeline: [[String: Any]] = []
        var excludedIDs: Set<UInt32> = []
        var commandIndex = 0
        var nativeFocusCount = 0
        var inbox = PreviewCommandInbox(pid: pid, token: previewToken)
        var previewCommands: [[String: Any]] = []
        var requireFrontmostForEffects = false
        // CG display bounds use the AX top-left coordinate domain.
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let canvas = Rect(x: bounds.minX + 40, y: bounds.minY + 100,
                          width: min(900, bounds.width - 80), height: min(360, bounds.height - 180))
        guard canvas.isValid else { report["reason"] = "No usable fixture canvas"; return report }
        let session = ScopedLayoutSession(ownerPID: pid, canvas: canvas,
            ownership: preview ? .frontmostApplication : .applicationLocalFixture)
        let ticket = session.ticket
        defer { session.stop() }
        func pause() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04)) }
        func nativeIdentityValid(_ element: AXUIElement, _ wid: UInt32) -> Bool {
            var owner: pid_t = 0
            return child.isRunning && AXUIElementGetPid(element, &owner) == .success && owner == pid &&
                paperi_window_id(element) == wid && attribute(element, kAXRoleAttribute) as? String == "AXWindow"
        }
        func identityValid(_ element: AXUIElement, _ wid: UInt32) -> Bool {
            session.accepts(ticket) && nativeIdentityValid(element, wid) &&
                (!requireFrontmostForEffects || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
        }
        func membership(_ wid: UInt32) -> UInt64? {
            guard let spaces = paperi_copy_window_spaces(wid) as? [NSNumber], spaces.count == 1 else { return nil }
            return spaces[0].uint64Value
        }
        func classification(_ element: AXUIElement, _ wid: UInt32) -> Classification {
            var movable = DarwinBoolean(false), resizable = DarwinBoolean(false)
            let move = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &movable)
            let size = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
            let parent = attribute(element, kAXParentAttribute)
            let level = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?
                .first?[kCGWindowLayer as String] as? Int
            return WindowPolicy.classify(WindowFacts(bundleID: "dev.paperi.disposable-lifecycle",
                role: attribute(element, kAXRoleAttribute) as? String,
                subrole: attribute(element, kAXSubroleAttribute) as? String,
                isRoot: parent.map { CFEqual($0, application) },
                movable: move == .success ? movable.boolValue : nil,
                resizable: size == .success ? resizable.boolValue : nil,
                fullscreen: attribute(element, "AXFullScreen") as? Bool,
                minimized: attribute(element, kAXMinimizedAttribute) as? Bool, level: level))
        }
        func matches(_ a: Rect, _ b: Rect) -> Bool {
            zip([a.x, a.y, a.width, a.height], [b.x, b.y, b.width, b.height]).allSatisfy { abs($0 - $1) <= 2 }
        }
        func refreshFocus() throws {
            let focused = attribute(application, kAXFocusedWindowAttribute)
            var id: UInt32?
            var facts = WindowPolicy.classify(WindowFacts(bundleID: "dev.paperi.disposable-lifecycle"))
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let ref = focused as! AXUIElement
                let wid = paperi_window_id(ref)
                AXUIElementSetMessagingTimeout(ref, 0.15)
                if wid > 0, identityValid(ref, wid) { id = wid; facts = classification(ref, wid) }
            }
            try session.focus(windowID: id, ownerPID: id == nil ? nil : pid, classification: facts, ticket: ticket)
            focusTimeline.append(["windowID": id ?? 0, "eligibility": facts.eligibility.rawValue,
                                  "suppressed": session.state.interactionSuppressed])
        }
        func apply() -> (writes: Int, confirmed: Bool) {
            guard session.accepts(ticket), let placements = try? session.state.layout.placements(in: canvas) else { return (0, false) }
            var writes = 0
            for placement in placements {
                let wid = placement.windowID
                guard let ref = references[wid], identityValid(ref, wid), membership(wid) == session.spaceID,
                      classification(ref, wid).eligibility == .tiled else { return (writes, false) }
                // Expected AX echoes do not trigger another layout. Changed-frame
                // comparison also avoids rewriting an unchanged surviving slot.
                if let observed = frame(ref), matches(observed, placement.frame) { continue }
                var point = CGPoint(x: placement.frame.x, y: placement.frame.y)
                var size = CGSize(width: placement.frame.width, height: placement.frame.height)
                guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return (writes, false) }
                session.expect(windowID: wid, frame: placement.frame, now: ProcessInfo.processInfo.systemUptime, ticket: ticket)
                for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)] {
                    guard identityValid(ref, wid),
                          AXUIElementSetAttributeValue(ref, name as CFString, value) == .success else { return (writes, false) }
                    writes += 1
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            repeat {
                if placements.allSatisfy({ placement in
                    guard let ref = references[placement.windowID], identityValid(ref, placement.windowID),
                          let observed = frame(ref) else { return false }
                    return matches(observed, placement.frame)
                }) { return (writes, true) }
                pause()
            } while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline
            return (writes, false)
        }
        func stopAdapter() -> [String: Any] {
            if let stoppedReport { return stoppedReport }
            let originalSpace = session.spaceID
            session.stop() // Revoke all ordinary effects before restoration begins.
            let teardown = recorder.stop()
            var rows: [[String: Any]] = []
            let restored = recovery.restore(managementStopped: !session.running) { wid, target in
                var row: [String: Any] = ["windowID": wid,
                    "original": [target.x, target.y, target.width, target.height]]
                var errors: [Int32] = []
                @MainActor func authorized() -> Bool {
                    guard let ref = references[wid] else { return false }
                    return nativeIdentityValid(ref, wid) && membership(wid) == originalSpace &&
                        classification(ref, wid).eligibility == .tiled
                }
                guard let ref = references[wid], authorized() else {
                    row["confirmed"] = false; row["reason"] = "Reference/ownership/presentation changed"
                    rows.append(row); return false
                }
                if frame(ref).map({ matches($0, target) }) != true {
                    var point = CGPoint(x: target.x, y: target.y)
                    var size = CGSize(width: target.width, height: target.height)
                    guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else {
                        row["confirmed"] = false; rows.append(row); return false
                    }
                    for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)] {
                        guard authorized() else { errors.append(AXError.invalidUIElement.rawValue); break }
                        errors.append(AXUIElementSetAttributeValue(ref, name as CFString, value).rawValue)
                        restoreWriteCount += 1
                    }
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 1.5
                var observed: Rect?
                repeat {
                    if authorized(), let value = frame(ref), matches(value, target) { observed = value; break }
                    pause()
                } while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline
                let confirmed = errors.allSatisfy { $0 == 0 } && observed != nil
                row["writeErrors"] = errors; row["confirmed"] = confirmed
                if let observed { row["observed"] = [observed.x, observed.y, observed.width, observed.height] }
                rows.append(row)
                return confirmed
            } ?? [:]
            let result: [String: Any] = ["teardown": teardown, "restorations": rows,
                "allRestored": restored.values.allSatisfy { $0 }, "restoredCount": restored.filter { $0.value }.count,
                "restoreWriteCount": restoreWriteCount]
            stoppedReport = result
            return result
        }
        defer { _ = stopAdapter() }
        func finishPreview(reason: String) -> [String: Any] {
            let stopped = stopAdapter()
            let teardown = stopped["teardown"] as? [String: Any] ?? [:]
            var checks = ["twoFixtureDocuments": created.count == 2,
                "effectsConfirmed": timeline.allSatisfy { $0["confirmed"] as? Bool == true },
                "survivingFramesRestored": stopped["allRestored"] as? Bool == true,
                "nativeSourcesRemoved": teardown["sourcesStillInstalled"] as? Int == 0,
                "managementRevoked": !session.accepts(ticket), "noFailures": failures.isEmpty]
            if automatedPreview {
                checks["nativeInputSequence"] = previewCommands.compactMap { $0["action"] as? String } == ["grow", "shrink", "stop"]
                checks["keyEquivalentsDispatched"] = previewCommands.filter { $0["source"] as? String == "keyEquivalent" }.count == 2
                checks["buttonStopDispatched"] = previewCommands.last?["source"] as? String == "button" && reason == "stopControl"
                checks["frontmostCommandsApplied"] = previewCommands.count == 3 && previewCommands.prefix(2).allSatisfy {
                    $0["accepted"] as? Bool == true && $0["confirmed"] as? Bool == true && ($0["writeCount"] as? Int ?? 0) > 0
                }
                checks["twoLiveFramesRestored"] = stopped["restoredCount"] as? Int == 2
            }
            var result = report
            result["mode"] = "interactiveDisposablePreview"; result["stopReason"] = reason
            result["checks"] = checks; result["stop"] = stopped; result["previewCommands"] = previewCommands
            result["timeline"] = timeline; result["failures"] = failures
            result["result"] = checks.values.allSatisfy { $0 } ? "passed" : "failed"
            return result
        }
        var consumed = 0
        let deadline = ProcessInfo.processInfo.systemUptime + (preview ? (automatedPreview ? 12 : 60) : (interaction ? 18 : 15))
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            recorder.reconcileNow()
            while consumed < queued.count {
                let row = queued[consumed]; consumed += 1
                guard row["pid"] as? Int32 == pid, let event = row["event"] as? String else { continue }
                if (interaction || preview) && [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification].contains(event) {
                    nativeFocusCount += 1
                    do { try refreshFocus() } catch { failures.append("Invalid focus transition") }
                    continue
                }
                guard
                      let wid = row["windowID"] as? UInt32, wid > 0 else { continue }
                do {
                    let needsLayout: Bool
                    var label = event
                    if event == kAXMovedNotification || event == kAXResizedNotification {
                        notificationCount += 1
                        guard let ref = references[wid], identityValid(ref, wid), let observed = frame(ref) else { continue }
                        if case .expected = session.observe(windowID: wid, frame: observed,
                                                          now: ProcessInfo.processInfo.systemUptime, ticket: ticket) {
                            echoCount += 1; continue
                        }
                        guard externalResize || preview, event == kAXResizedNotification, let space = membership(wid), space == session.spaceID,
                              let slot = session.slots[wid], let index = session.state.layout.index(of: slot),
                              abs(session.state.layout.columns[index.column].width - observed.width) > 2 else { continue }
                        let width = min(canvas.width, observed.width)
                        needsLayout = try session.resize(windowID: wid, ownerPID: pid, spaceID: space, width: width,
                                                         classification: classification(ref, wid), ticket: ticket)
                        guard needsLayout else { continue }
                        adoptedWidths.append(width)
                        label = "externalResize"
                    } else if event == kAXWindowCreatedNotification {
                        guard session.slots[wid] == nil else { failures.append("Duplicate create identity"); continue }
                        let refs = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
                        func reference(_ name: String) -> AXUIElement? {
                            guard let value = attribute(application, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                            return (value as! AXUIElement)
                        }
                        let discovery = RecorderWindowDiscovery.collect(enumerated: refs,
                            focused: reference(kAXFocusedWindowAttribute), main: reference(kAXMainWindowAttribute), pid: pid) { ref in
                            var owner: pid_t = 0
                            let result = AXUIElementGetPid(ref, &owner)
                            return (result == .success ? owner : nil, attribute(ref, kAXRoleAttribute) as? String)
                        }
                        guard let ref = discovery.windows.map(\.element).first(where: { paperi_window_id($0) == wid }),
                              identityValid(ref, wid) else { failures.append("Unavailable created window"); continue }
                        AXUIElementSetMessagingTimeout(ref, 0.15)
                        let eligibility = classification(ref, wid)
                        if (interaction || preview) && eligibility.eligibility == .excluded { excludedIDs.insert(wid); continue }
                        guard eligibility.eligibility == .tiled else { failures.append("Ineligible fixture"); continue }
                        guard let space = membership(wid) else { failures.append("Unavailable created window Space"); continue }
                        guard let original = frame(ref), original.isValid else { failures.append("Original frame unavailable"); continue }
                        guard session.spaceID == nil || space == session.spaceID else { failures.append("Cross-Space scope rejected"); continue }
                        needsLayout = try session.insert(windowID: wid, ownerPID: pid, spaceID: space,
                            classification: eligibility, knownSingleton: true, ticket: ticket)
                        references[wid] = ref; created.append(wid)
                        recovery.remember(windowID: wid, frame: original)
                    } else if event == kAXUIElementDestroyedNotification, session.slots[wid] != nil {
                        needsLayout = try session.remove(windowID: wid, ticket: ticket)
                        references.removeValue(forKey: wid); destroyed.append(wid)
                        recovery.remove(windowID: wid)
                    } else { continue }
                    let effects = needsLayout ? apply() : (writes: 0, confirmed: true)
                    if !effects.confirmed { failures.append("Unconfirmed layout effect") }
                    timeline.append(["event": label, "windowID": wid,
                        "slotCount": session.state.layout.columns.reduce(0) { $0 + $1.slots.count },
                        "writeCount": effects.writes, "confirmed": effects.confirmed])
                } catch { failures.append("Reducer rejected lifecycle event") }
            }
            if preview {
                let rows = ((try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? [])
                    .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                for row in rows {
                    guard let command = inbox.consume(row, knownWindows: Set(session.slots.keys)) else { continue }
                    if command.action == .stop {
                        previewCommands.append(["action": "stop", "source": command.source, "accepted": true,
                                                "confirmed": true, "writeCount": 0])
                        return finishPreview(reason: "stopControl")
                    }
                    do {
                        try refreshFocus()
                        let focused = session.state.osFocusedWindow == command.windowID
                        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
                        let intent: Bool
                        if focused {
                            switch command.action {
                            case .grow, .shrink:
                                intent = try session.resizeFocused(by: command.action == .grow ? 0.1 : -0.1,
                                    frontmostPID: frontmost, ticket: ticket)
                            case .slurp:
                                intent = try session.slurpFocused(frontmostPID: frontmost, ticket: ticket)
                            case .barf:
                                intent = try session.barfFocused(frontmostPID: frontmost, ticket: ticket)
                            case .nextSpace:
                                if frontmost == pid, let currentSpace = session.spaceID,
                                   let ref = references[command.windowID],
                                   let title = attribute(ref, kAXTitleAttribute) as? String, title.contains(previewToken),
                                   let disp = DisplaySpaceCoordinator.liveTopologies().first(where: { $0.userSpaces.contains(currentSpace) }),
                                   disp.userSpaces.count >= 2,
                                   let idx = disp.userSpaces.firstIndex(of: currentSpace) {
                                    let dest = disp.userSpaces[(idx + 1) % disp.userSpaces.count]
                                    let res = SpaceTransfer.moveWindowViaMissionControl(windowID: command.windowID, expectedTitle: title, toSpace: dest)
                                    intent = res["transferred"] as? Bool == true
                                } else { intent = false }
                            case .stop:
                                intent = false
                            }
                        } else { intent = false }
                        requireFrontmostForEffects = true
                        let effects = intent ? apply() : (writes: 0, confirmed: true)
                        requireFrontmostForEffects = false
                        previewCommands.append(["action": command.action.rawValue, "source": command.source,
                            "accepted": intent, "confirmed": effects.confirmed, "writeCount": effects.writes])
                        if !effects.confirmed { failures.append("Preview command effect unconfirmed") }
                    } catch { failures.append("Preview command rejected invalid geometry") }
                }
            }
            if interaction && commandIndex < 3 && ProcessInfo.processInfo.systemUptime - started >= [6.0, 8.0, 10.0][commandIndex] {
                do {
                    try refreshFocus() // Revalidate ownership immediately before dispatch.
                    let before = session.state.layout
                    let intent = try session.resizeFocused(by: 0.1,
                        frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier, ticket: ticket)
                    let effects = intent ? apply() : (writes: 0, confirmed: true)
                    commandTimeline.append(["phase": commandIndex, "suppressed": session.state.interactionSuppressed,
                        "changed": session.state.layout != before, "intent": intent, "writeCount": effects.writes,
                        "confirmed": effects.confirmed,
                        "widths": session.state.layout.columns.map(\.width), "slots": session.state.layout.columns.flatMap { $0.slots.map(\.id) }])
                    if !effects.confirmed { failures.append("Unconfirmed command effect") }
                } catch { failures.append("Command dispatch failed") }
                commandIndex += 1
            }
            if stopWhileOpen && ProcessInfo.processInfo.systemUptime - started >= 6 {
                let liveCount = session.slots.count
                let managed = (try? session.state.layout.placements(in: canvas)) ?? []
                let movedCount = references.filter { wid, ref in
                    guard let observed = frame(ref), let target = managed.first(where: { $0.windowID == wid }) else { return false }
                    return matches(target.frame, observed)
                }.count
                let stopped = stopAdapter()
                let staleEffects = apply()
                let staleCommand = (try? session.resizeFocused(by: 0.1, frontmostPID: pid, ticket: ticket)) ?? true
                let writesBeforeRepeatedStop = restoreWriteCount
                _ = stopAdapter()
                let teardown = stopped["teardown"] as? [String: Any] ?? [:]
                let checks = ["twoLiveWindowsAtStop": liveCount == 2 && created.count == 2 && destroyed.isEmpty,
                    "managedFramesConfirmedBeforeStop": movedCount == 2,
                    "twoOriginalFramesRestored": stopped["restoredCount"] as? Int == 2 && stopped["allRestored"] as? Bool == true,
                    "restorationWritesExercised": restoreWriteCount == 6,
                    "managementStateCleared": session.state.layout.columns.isEmpty && session.slots.isEmpty,
                    "oldTicketRevoked": !session.accepts(ticket),
                    "staleWorkRejected": !staleCommand && staleEffects.writes == 0 && !staleEffects.confirmed,
                    "repeatedStopDoesNotWrite": restoreWriteCount == writesBeforeRepeatedStop,
                    "nativeSourcesRemoved": teardown["sourcesStillInstalled"] as? Int == 0,
                    "noFailures": failures.isEmpty && timeline.allSatisfy { $0["confirmed"] as? Bool == true }]
                report["checks"] = checks; report["stop"] = stopped; report["timeline"] = timeline
                report["failures"] = failures
                report["result"] = checks.values.allSatisfy { $0 } ? "passed" : "failed"
                return report
            }
            if destroyed.count == 2 {
                if preview { return finishPreview(reason: "documentsClosed") }
                break
            }
            // Polling only discovers/subscribes; it never synthesizes removals.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        if preview { return finishPreview(reason: child.isRunning ? "timeLimit" : "fixtureExited") }
        let layoutEmptyBeforeStop = session.state.layout.columns.isEmpty && session.slots.isEmpty
        let stop = stopAdapter()
        let teardown = stop["teardown"] as? [String: Any] ?? [:]
        let truthRows = ((try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? [])
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let truthIDs = Set(truthRows.flatMap { ($0["tabWindows"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? UInt32 } })
        let lifecycleRows = timeline.filter { $0["event"] as? String != "externalResize" }
        var checks: [String: Bool] = [
            "twoUniqueCreates": created.count == 2 && Set(created).count == 2,
            "fixtureIdentitiesMatch": truthIDs.count == 2 && Set(created) == truthIDs,
            "matchingDestroys": destroyed.count == 2 && Set(destroyed) == Set(created),
            "lifecycleOrder": lifecycleRows.compactMap { $0["slotCount"] as? Int } == [1, 2, 1, 0],
            "effectsConfirmed": timeline.count == (externalResize ? 5 : 4) && timeline.allSatisfy { $0["confirmed"] as? Bool == true },
            "frameEffectsExercised": timeline.contains { ($0["writeCount"] as? Int ?? 0) > 0 },
            "survivorReflowExercised": lifecycleRows.count == 4 && (lifecycleRows[2]["writeCount"] as? Int ?? 0) > 0,
            "echoNotificationsObserved": echoCount > 0,
            "finalLayoutEmpty": layoutEmptyBeforeStop,
            "nativeSourcesRemoved": teardown["sourcesStillInstalled"] as? Int == 0,
            "survivingFramesRestored": stop["allRestored"] as? Bool == true,
            "noFailures": failures.isEmpty]
        if stopWhileOpen { checks["stopWhileOpenExercised"] = false }
        if externalResize {
            let truthWidth = truthRows.first { $0["event"] as? String == "externalResize" }?["externalResizeWidth"] as? Double
            checks["externalWidthAdoptedOnce"] = adoptedWidths.count == 1 && truthWidth.map { abs(adoptedWidths[0] - $0) <= 2 } == true
            checks["resizePreservesSlotCount"] = timeline.filter { $0["event"] as? String == "externalResize" }
                .allSatisfy { $0["slotCount"] as? Int == 2 }
            checks["resizeReflowExercised"] = timeline.contains {
                $0["event"] as? String == "externalResize" && ($0["writeCount"] as? Int ?? 0) > 0
            }
        }
        if interaction {
            checks["panelExcluded"] = excludedIDs.count == 1 && excludedIDs.isDisjoint(with: Set(created))
            checks["nativeFocusObserved"] = nativeFocusCount > 0 && focusTimeline.contains { $0["eligibility"] as? String == "excluded" } &&
                focusTimeline.contains { $0["eligibility"] as? String == "tiled" }
            checks["commandSequence"] = commandTimeline.count == 3 &&
                commandTimeline.compactMap { $0["changed"] as? Bool } == [true, false, true] &&
                commandTimeline.compactMap { $0["suppressed"] as? Bool } == [false, true, false]
            checks["noPanelCommandWrites"] = commandTimeline.count == 3 && commandTimeline[1]["writeCount"] as? Int == 0
            checks["commandEffectsConfirmed"] = commandTimeline.count == 3 && commandTimeline.allSatisfy { $0["confirmed"] as? Bool == true } &&
                (commandTimeline[0]["writeCount"] as? Int ?? 0) > 0 && (commandTimeline[2]["writeCount"] as? Int ?? 0) > 0
            checks["logicalSlotsPreserved"] = commandTimeline.count == 3 && commandTimeline.allSatisfy {
                $0["slots"] as? [String] == commandTimeline[0]["slots"] as? [String]
            }
            if commandTimeline.count == 3,
               let first = commandTimeline[0]["widths"] as? [Double],
               let blocked = commandTimeline[1]["widths"] as? [Double],
               let recovered = commandTimeline[2]["widths"] as? [Double], first.count == 2, recovered.count == 2 {
                checks["noDeferredCommandReplay"] = first == blocked &&
                    abs(recovered[0] - first[0] - canvas.width * 0.1) <= 2 && recovered[1] == first[1]
            } else { checks["noDeferredCommandReplay"] = false }
        }
        report["checks"] = checks; report["timeline"] = timeline
        report["failures"] = failures; report["echoNotifications"] = echoCount
        report["frameNotifications"] = notificationCount; report["adoptedWidths"] = adoptedWidths
        report["teardown"] = teardown
        report["stop"] = stop
        session.stop()
        checks["stoppedSessionRejectsOldTicket"] = !session.accepts(ticket)
        report["checks"] = checks
        if interaction {
            report["focusTimeline"] = focusTimeline; report["commandTimeline"] = commandTimeline
            report["nativeFocusNotifications"] = nativeFocusCount
        }
        report["result"] = checks.values.allSatisfy { $0 } ? "passed" : "failed"
        return report
    }
}
