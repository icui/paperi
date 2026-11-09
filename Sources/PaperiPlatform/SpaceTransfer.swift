import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

/// Executes guarded cross-Space window transfers via the Mission Control AX tree
/// and confirms both WindowServer Space membership and active-Space follow.
/// Never touches any window unless its title matches the caller's unique owned token.
@MainActor enum SpaceTransfer {
    private static func pause(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func axChildren(_ element: AXUIElement, identifier: String) -> [AXUIElement] {
        guard let children = axValue(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
        return children.filter { (axValue($0, kAXIdentifierAttribute as String) as? String) == identifier }
    }

    private static func axCenter(_ element: AXUIElement) -> CGPoint? {
        if let raw = axValue(element, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 {
                return CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        guard let posRaw = axValue(element, kAXPositionAttribute as String),
              let sizeRaw = axValue(element, kAXSizeAttribute as String),
              CFGetTypeID(posRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &s), s.width > 0, s.height > 0 else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }

    private static func missionControlGroup() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return axChildren(app, identifier: "mc").first
    }

    private static func windowSpaces(_ windowID: UInt32) -> [UInt64] {
        (paperi_copy_window_spaces(windowID) as? [NSNumber] ?? []).map(\.uint64Value)
    }

    private static func displaySpaceIDs(containing spaceID: UInt64) -> [UInt64] {
        guard let displays = paperi_copy_display_spaces() as? [[String: Any]] else { return [] }
        for display in displays {
            let ids = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            if ids.contains(spaceID) { return ids }
        }
        return []
    }

    static func moveWindowViaMissionControl(windowID: UInt32, expectedTitle: String,
                                            toSpace destinationSpace: UInt64,
                                            screenOrigin: CGPoint = .zero) -> [String: Any] {
        var report: [String: Any] = [
            "windowID": windowID,
            "destinationSpace": destinationSpace,
            "activeSpaceBefore": paperi_active_space(),
            "membershipBefore": windowSpaces(windowID),
            "transferred": false
        ]
        guard AXIsProcessTrusted(), windowID > 0, !expectedTitle.isEmpty else {
            report["failure"] = "Invalid window/title or missing Accessibility trust"
            return report
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let savedCursor = CGEvent(source: nil)?.location ?? .zero
        var buttonHeld = false
        var heldPoint = CGPoint.zero

        func postMouse(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            event.post(tap: .cghidEventTap)
            if type == .leftMouseDown || type == .leftMouseDragged {
                buttonHeld = true; heldPoint = point
            } else if type == .leftMouseUp {
                buttonHeld = false
            }
        }

        func postEscape() {
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }

        defer {
            if buttonHeld { postMouse(.leftMouseUp, heldPoint) }
            CGWarpMouseCursorPosition(savedCursor)
        }

        let mcURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: mcURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)

        var opened = false
        for _ in 0..<30 {
            if missionControlGroup() != nil { opened = true; break }
            pause(0.1)
        }
        report["missionControlOpened"] = opened
        guard opened else {
            report["failure"] = "Mission Control did not open"
            return report
        }

        func fail(_ reason: String) -> [String: Any] {
            report["failure"] = reason
            postEscape()
            pause(0.8)
            return report
        }

        postMouse(.mouseMoved, CGPoint(x: screenOrigin.x + 10, y: screenOrigin.y + 10))
        pause(0.8)

        var expandAttempts = 0
        var barSettled = false
        var start = CGPoint.zero
        var end = CGPoint.zero
        var targetThumbnails: [AXUIElement] = []
        var targetIndex = 0

        while true {
            guard let group = missionControlGroup() else {
                return fail("Mission Control closed before drag")
            }
            var windowElement: AXUIElement?
            var displayGroup: AXUIElement?
            for display in axChildren(group, identifier: "mc.display") {
                for list in axChildren(display, identifier: "mc.windows") {
                    for candidate in (axValue(list, kAXChildrenAttribute as String) as? [AXUIElement] ?? []) {
                        if (axValue(candidate, kAXTitleAttribute as String) as? String) == expectedTitle {
                            if windowElement != nil { return fail("Title matched more than one Mission Control window") }
                            windowElement = candidate; displayGroup = display
                        }
                    }
                }
            }
            guard let winEl = windowElement, let dispEl = displayGroup else {
                return fail("Owned window not found in Mission Control")
            }
            var thumbnails: [AXUIElement] = []
            for spaces in axChildren(dispEl, identifier: "mc.spaces") {
                for list in axChildren(spaces, identifier: "mc.spaces.list") {
                    thumbnails = axValue(list, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
                }
            }
            let spaceIDs = displaySpaceIDs(containing: destinationSpace)
            guard let idx = spaceIDs.firstIndex(of: destinationSpace), thumbnails.count == spaceIDs.count else {
                return fail("Space thumbnail order unverified")
            }
            guard let s = axCenter(winEl), let e = axCenter(thumbnails[idx]) else {
                return fail("Mission Control frame unavailable")
            }
            if e.y < screenOrigin.y + 8 {
                if expandAttempts >= 5 { return fail("Spaces bar did not expand") }
                expandAttempts += 1
                report["thumbnailExpandAttempts"] = expandAttempts
                postMouse(.mouseMoved, CGPoint(x: e.x, y: screenOrigin.y + 4))
                pause(0.1)
                postMouse(.mouseMoved, CGPoint(x: e.x + 2, y: screenOrigin.y))
                pause(0.8)
                continue
            }
            if !barSettled {
                barSettled = true
                pause(0.45)
                continue
            }
            start = s; end = e; targetThumbnails = thumbnails; targetIndex = idx
            break
        }

        if CGEventSource.buttonState(.hidSystemState, button: .left) {
            return fail("Physical mouse button held")
        }

        postMouse(.mouseMoved, start)
        pause(0.15)
        postMouse(.leftMouseDown, start)
        for step in 1...14 {
            pause(0.04)
            let t = CGFloat(step) / 14.0
            postMouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        pause(0.14)
        let drop = axCenter(targetThumbnails[targetIndex]) ?? end
        postMouse(.leftMouseDragged, drop)
        pause(0.45)
        postMouse(.leftMouseUp, drop)
        report["dragStart"] = [start.x, start.y]
        report["dragEnd"] = [drop.x, drop.y]

        pause(0.6)
        let click = axCenter(targetThumbnails[targetIndex]) ?? drop
        postMouse(.mouseMoved, click)
        pause(0.05)
        postMouse(.leftMouseDown, click)
        pause(0.08)
        postMouse(.leftMouseUp, click)

        pause(1.3)
        if missionControlGroup() != nil {
            postEscape()
            pause(0.8)
        }

        var confirmed = false
        for _ in 0..<30 {
            if windowSpaces(windowID) == [destinationSpace] && paperi_active_space() == destinationSpace {
                confirmed = true
                break
            }
            pause(0.1)
        }
        if confirmed {
            // Allow the macOS Space transition animation to finish before AX writes on the destination Space.
            pause(0.6)
        }
        report["membershipAfter"] = windowSpaces(windowID)
        report["activeSpaceAfter"] = paperi_active_space()
        report["transferred"] = confirmed
        return report
    }
}

extension Diagnostics {
    /// End-to-end live validation of `DisplaySpaceCoordinator` + Mission Control
    /// cross-Space window transfer + per-Space `ScopedLayoutSession` placements +
    /// `FrameRestorationJournal` recovery on newly spawned disposable windows only.
    @MainActor public static func probeSpaceSession() -> [String: Any] {
        var report: [String: Any] = [
            "schemaVersion": 1,
            "result": "failed",
            "scope": "Two disposable preview windows; cross-Space session transfer and restoration via DisplaySpaceCoordinator"
        ]
        guard AXIsProcessTrusted() else {
            report["result"] = "unsupported"
            report["reason"] = "Accessibility trust required"
            return report
        }
        let topologies = DisplaySpaceCoordinator.liveTopologies()
        let activeSpace = paperi_active_space()
        guard let display = topologies.first(where: { $0.spaces.contains { $0.id == activeSpace } }) ?? topologies.first,
              display.userSpaces.contains(activeSpace),
              let destinationSpace = display.userSpaces.first(where: { $0 != activeSpace }) else {
            report["result"] = "unsupported"
            report["reason"] = "Requires an active user Space and a second user Space on the same display"
            return report
        }
        let sourceSpace = activeSpace
        report["sourceSpace"] = sourceSpace
        report["destinationSpace"] = destinationSpace

        let bounds = CGDisplayBounds(CGMainDisplayID())
        let canvas = Rect(x: bounds.minX + 40, y: bounds.minY + 100,
                          width: min(900, bounds.width - 80), height: min(360, bounds.height - 180))
        guard canvas.isValid else {
            report["reason"] = "No usable fixture canvas"
            return report
        }

        let child = Process()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paperi-space-session-\(UUID())")
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
        child.arguments = [log.path, "--space-tab-session", "--preview-token", previewToken]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() }
        catch { report["reason"] = "Build all products to supply sibling PaperiAXFixture"; return report }

        let pid = child.processIdentifier
        report["fixturePID"] = pid

        let coordinator = DisplaySpaceCoordinator(
            ownerPID: pid,
            displays: [DisplaySpaceTopology(displayUUID: display.displayUUID, canvas: canvas,
                                            spaces: display.spaces, activeSpaceID: sourceSpace)],
            ownership: .applicationLocalFixture
        )
        defer { coordinator.stop() }

        var queued: [[String: Any]] = []
        let recorder = EventRecorder(workspaceCenter: NotificationCenter(), runningApplications: {
            NSRunningApplication(processIdentifier: pid).map { [$0] } ?? []
        }, observeWorkspaceEvents: false, emit: { queued.append($0) })
        recorder.start()
        defer { recorder.stop() }

        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var references: [UInt32: AXUIElement] = [:]
        var recovery = FrameRestorationJournal()
        var timeline: [[String: Any]] = []
        var failures: [String] = []
        let tiled = WindowPolicy.classify(
            WindowFacts(bundleID: "dev.paperi.disposable-space-session", role: "AXWindow",
                        subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true, level: 0)
        )

        func pause(_ seconds: TimeInterval = 0.05) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }
        func membership(_ wid: UInt32) -> UInt64? {
            guard let spaces = paperi_copy_window_spaces(wid) as? [NSNumber], spaces.count == 1 else { return nil }
            return spaces[0].uint64Value
        }
        func matches(_ a: Rect, _ b: Rect) -> Bool {
            zip([a.x, a.y, a.width, a.height], [b.x, b.y, b.width, b.height]).allSatisfy { abs($0 - $1) <= 2 }
        }
        func nativeIdentityValid(_ element: AXUIElement, _ wid: UInt32) -> Bool {
            var owner: pid_t = 0
            return child.isRunning && AXUIElementGetPid(element, &owner) == .success && owner == pid &&
                paperi_window_id(element) == wid && attribute(element, kAXRoleAttribute) as? String == "AXWindow"
        }
        func refreshReferences(waitFor windowIDs: [UInt32] = []) {
            let deadline = ProcessInfo.processInfo.systemUptime + 2.0
            repeat {
                for ref in attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                    let wid = paperi_window_id(ref)
                    if wid > 0 {
                        AXUIElementSetMessagingTimeout(ref, 0.25)
                        if nativeIdentityValid(ref, wid) { references[wid] = ref }
                    }
                }
                if windowIDs.isEmpty || windowIDs.allSatisfy({ wid in references[wid].map { nativeIdentityValid($0, wid) } == true }) {
                    break
                }
                pause(0.1)
            } while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline
        }
        func apply(spaceID: UInt64) -> (writes: Int, confirmed: Bool) {
            guard coordinator.running, let session = coordinator.sessions[spaceID],
                  session.accepts(session.ticket),
                  let placements = try? session.state.layout.placements(in: session.canvas) else { return (0, false) }
            refreshReferences(waitFor: placements.map(\.windowID))
            var writes = 0
            for placement in placements {
                let wid = placement.windowID
                guard let ref = references[wid], nativeIdentityValid(ref, wid), membership(wid) == spaceID else { return (writes, false) }
                if let observed = frame(ref), matches(observed, placement.frame) { continue }
                var point = CGPoint(x: placement.frame.x, y: placement.frame.y)
                var size = CGSize(width: placement.frame.width, height: placement.frame.height)
                guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return (writes, false) }
                session.expect(windowID: wid, frame: placement.frame, now: ProcessInfo.processInfo.systemUptime, ticket: session.ticket)
                for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)] {
                    guard nativeIdentityValid(ref, wid),
                          AXUIElementSetAttributeValue(ref, name as CFString, value) == .success else { return (writes, false) }
                    writes += 1
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            repeat {
                if placements.allSatisfy({ placement in
                    guard let ref = references[placement.windowID], nativeIdentityValid(ref, placement.windowID),
                          let observed = frame(ref) else { return false }
                    return matches(observed, placement.frame)
                }) { return (writes, true) }
                pause(0.04)
            } while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline
            return (writes, false)
        }

        // 1. Learn the two-tab native container externally via NativeTabMembership and admit into coordinator on sourceSpace.
        var learnedGroup: NativeTabMembership?
        var memberSpaces = NativeTabMemberSpaces()
        let learnDeadline = ProcessInfo.processInfo.systemUptime + 14.0
        while child.isRunning && learnedGroup == nil && ProcessInfo.processInfo.systemUptime < learnDeadline {
            recorder.reconcileNow()
            refreshReferences()
            let evidence = recorder.tabEvidence(processID: pid)
            if let app = (evidence["applications"] as? [[String: Any]])?.first {
                if let nodes = app["nodes"] as? [[String: Any]], let roots = app["roots"] as? [Int],
                   let observed = app["observedRoots"] as? [Int], let scope = app["identityScope"] as? String {
                    let capture = TabSelectionEvidence.inspect(nodes: nodes, roots: roots + observed,
                        complete: app["truncated"] as? Bool == false && app["identityTruncated"] as? Bool == false)
                    for group in capture.groups ?? [] where group.selected != nil {
                        if let ref = references[group.window], nativeIdentityValid(ref, group.window), let sid = membership(group.window) {
                            memberSpaces.observe(scope: scope, group: group.group, selected: group.window, space: sid)
                        }
                    }
                }
                let candidates = NativeTabMembership.inspect(app)
                if let candidate = candidates.first(where: { $0.members.count == 2 }),
                   candidate.members.allSatisfy({ references[$0] != nil }) {
                    let currentSpaces = Dictionary(uniqueKeysWithValues: candidate.members.compactMap { id in membership(id).map { (id, $0) } })
                    if memberSpaces.confirmedSpace(for: candidate, current: currentSpaces) == sourceSpace,
                       let activeRef = references[candidate.active], let orig = frame(activeRef), orig.isValid {
                        do {
                            if try coordinator.admitTabs(members: candidate.members, active: candidate.active,
                                                         ownerPID: pid, spaceID: sourceSpace, classification: tiled) {
                                recovery.remember(windowID: candidate.active, frame: orig)
                                let effects = apply(spaceID: sourceSpace)
                                if !effects.confirmed { failures.append("Initial source placement unconfirmed") }
                                timeline.append(["phase": "admitTabs", "members": candidate.members, "active": candidate.active,
                                                 "spaceID": sourceSpace, "writeCount": effects.writes, "confirmed": effects.confirmed])
                                learnedGroup = candidate
                            }
                        } catch { failures.append("Coordinator rejected tab group admission") }
                    }
                }
            }
            pause(0.15)
        }

        guard let group = learnedGroup,
              let sourceSession = coordinator.sessions[sourceSpace],
              let destSession = coordinator.sessions[destinationSpace] else {
            report["failures"] = failures + ["Did not learn and admit two-tab container on source Space"]
            return report
        }

        let activeWid = group.active
        let initialSlot = sourceSession.slots[activeWid]
        let initialWidth = sourceSession.state.layout.columns.first?.width ?? 446

        guard let activeRef = references[activeWid],
              let activeTitle = attribute(activeRef, kAXTitleAttribute) as? String,
              activeTitle.contains(previewToken) else {
            report["failures"] = failures + ["Owned preview title unavailable on active tab representative"]
            return report
        }

        // 2. Outbound transfer: move the 2-tab container from sourceSpace -> destinationSpace via Mission Control + Coordinator.
        let outboundMC = SpaceTransfer.moveWindowViaMissionControl(
            windowID: activeWid, expectedTitle: activeTitle, toSpace: destinationSpace, screenOrigin: CGPoint(x: bounds.minX, y: bounds.minY)
        )
        report["outboundTransfer"] = outboundMC
        var outboundCoordinatorTransferred = false
        var outboundDestinationConfirmed = false
        if outboundMC["transferred"] as? Bool == true {
            if let moved = try? coordinator.transferContainer(containing: activeWid, to: destinationSpace, classification: tiled),
               moved.source == sourceSpace && moved.destination == destinationSpace {
                outboundCoordinatorTransferred = sourceSession.state.layout.columns.isEmpty &&
                    destSession.state.layout.columns.count == 1 &&
                    group.members.allSatisfy { destSession.slots[$0] == initialSlot && coordinator.spaceForWindow[$0] == destinationSpace }
                _ = try? destSession.resize(windowID: activeWid, ownerPID: pid, spaceID: destinationSpace,
                                            width: initialWidth + 40, classification: tiled, ticket: destSession.ticket)
                let destEffects = apply(spaceID: destinationSpace)
                outboundDestinationConfirmed = destEffects.confirmed && destEffects.writes > 0
                timeline.append(["phase": "outboundDestinationApply", "windowID": activeWid, "spaceID": destinationSpace,
                                 "writeCount": destEffects.writes, "confirmed": destEffects.confirmed])
            } else {
                failures.append("Coordinator failed outbound container transfer")
            }
        } else {
            failures.append("Mission Control outbound transfer failed")
        }

        // 3. Return transfer: move the 2-tab container from destinationSpace -> sourceSpace via Mission Control + Coordinator.
        var returnCoordinatorTransferred = false
        var returnSourceConfirmed = false
        if outboundCoordinatorTransferred {
            let returnMC = SpaceTransfer.moveWindowViaMissionControl(
                windowID: activeWid, expectedTitle: activeTitle, toSpace: sourceSpace, screenOrigin: CGPoint(x: bounds.minX, y: bounds.minY)
            )
            report["returnTransfer"] = returnMC
            if returnMC["transferred"] as? Bool == true {
                if let movedBack = try? coordinator.transferContainer(containing: activeWid, to: sourceSpace, classification: tiled),
                   movedBack.source == destinationSpace && movedBack.destination == sourceSpace {
                    returnCoordinatorTransferred = destSession.state.layout.columns.isEmpty &&
                        sourceSession.state.layout.columns.count == 1 &&
                        group.members.allSatisfy { sourceSession.slots[$0] == initialSlot && coordinator.spaceForWindow[$0] == sourceSpace }
                    _ = try? sourceSession.resize(windowID: activeWid, ownerPID: pid, spaceID: sourceSpace,
                                                  width: initialWidth + 80, classification: tiled, ticket: sourceSession.ticket)
                    let sourceEffects = apply(spaceID: sourceSpace)
                    returnSourceConfirmed = sourceEffects.confirmed && sourceEffects.writes > 0
                    timeline.append(["phase": "returnSourceApply", "windowID": activeWid, "spaceID": sourceSpace,
                                     "writeCount": sourceEffects.writes, "confirmed": sourceEffects.confirmed])
                } else {
                    failures.append("Coordinator failed return container transfer")
                }
            } else {
                failures.append("Mission Control return transfer failed")
            }
        }

        // 4. Stop coordinator/recorder and restore surviving frame on sourceSpace.
        refreshReferences(waitFor: [activeWid])
        coordinator.stop()
        let teardown = recorder.stop()
        var restoreRows: [[String: Any]] = []
        var restoreWriteCount = 0
        let restored = recovery.restore(managementStopped: !coordinator.running) { wid, target in
            var row: [String: Any] = ["windowID": wid, "original": [target.x, target.y, target.width, target.height]]
            guard let ref = references[wid], nativeIdentityValid(ref, wid), membership(wid) == sourceSpace else {
                row["confirmed"] = false; restoreRows.append(row); return false
            }
            if frame(ref).map({ matches($0, target) }) != true {
                var point = CGPoint(x: target.x, y: target.y)
                var size = CGSize(width: target.width, height: target.height)
                guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else {
                    row["confirmed"] = false; restoreRows.append(row); return false
                }
                for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)] {
                    _ = AXUIElementSetAttributeValue(ref, name as CFString, value)
                    restoreWriteCount += 1
                }
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            var observed: Rect?
            repeat {
                if let value = frame(ref), matches(value, target) { observed = value; break }
                pause(0.04)
            } while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline
            let ok = observed != nil
            row["confirmed"] = ok
            if let observed { row["observed"] = [observed.x, observed.y, observed.width, observed.height] }
            restoreRows.append(row)
            return ok
        } ?? [:]

        let checks: [String: Bool] = [
            "twoTabContainerLearnedAndAdmitted": group.members.count == 2 && initialSlot != nil,
            "outboundMissionControlTransferred": (report["outboundTransfer"] as? [String: Any])?["transferred"] as? Bool == true,
            "outboundCoordinatorTransferred": outboundCoordinatorTransferred,
            "outboundDestinationPlacementConfirmed": outboundDestinationConfirmed,
            "returnMissionControlTransferred": (report["returnTransfer"] as? [String: Any])?["transferred"] as? Bool == true,
            "returnCoordinatorTransferred": returnCoordinatorTransferred,
            "returnSourcePlacementConfirmed": returnSourceConfirmed,
            "logicalSlotsPreservedAcrossSpaces": initialSlot != nil && returnCoordinatorTransferred,
            "survivingFramesRestored": restored.count == 1 && restored.values.allSatisfy { $0 },
            "coordinatorStopped": !coordinator.running && coordinator.sessions.isEmpty,
            "nativeSourcesRemoved": teardown["sourcesStillInstalled"] as? Int == 0,
            "noFailures": failures.isEmpty
        ]
        report["checks"] = checks
        report["timeline"] = timeline
        report["failures"] = failures
        report["stop"] = [
            "allRestored": restored.values.allSatisfy { $0 },
            "restoredCount": restored.filter(\.value).count,
            "restoreWriteCount": restoreWriteCount,
            "restorations": restoreRows,
            "teardown": teardown
        ]
        report["result"] = checks.values.allSatisfy { $0 } ? "passed" : "failed"
        return report
    }
}
