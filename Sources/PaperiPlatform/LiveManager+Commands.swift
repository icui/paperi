import AppKit
@preconcurrency import ApplicationServices
import PaperiBridge
import PaperiCore

/// `paperi msg` commands, tray callbacks and status.
extension LiveManager {
    // MARK: commands

    public enum LiveError: Error, CustomStringConvertible {
        case accessibility
        public var description: String { "Accessibility trust is required (System Settings › Privacy & Security › Accessibility)" }
    }

    func focusedContext() -> (session: ScopedLayoutSession, space: UInt64, pid: pid_t, window: UInt32)? {
        if motionActive, let space = motionSpace, let session = coordinator.sessions[space],
           let focused = session.state.layout.focused, let loc = session.state.layout.index(of: focused) {
            let wid = session.state.layout.columns[loc.column].slots[loc.row].activeMember
            if let pid = pidForWindow[wid] { return (session, space, pid, wid) }
        }
        refresh()
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let focusedElement = value as! AXUIElement
        let wid = paperi_window_id(focusedElement)
        guard let space = coordinator.spaceForWindow[wid], let session = coordinator.sessions[space] else { return nil }
        return (session, space, pid, wid)
    }

    func focusThumbnail(_ wid: UInt32, in space: UInt64) {
        guard running, !paused, DisplayArrangement.currentProblem() == nil,
              coordinator.spaceForWindow[wid] == space,
              coordinator.display(forSpace: space)?.activeSpaceID == space,
              let session = coordinator.sessions[space], !session.state.interactionSuppressed,
              isActiveRepresentative(wid), let pid = pidForWindow[wid] else { return }
        cancelMotion(); motionFrames.removeAll()
        commandStarted = ProcessInfo.processInfo.systemUptime
        firstWriteMS = nil; finalWriteMS = nil; confirmedMS = nil
        try? session.focus(windowID: wid, ownerPID: pid, classification: Self.tiled, ticket: session.ticket)
        reveal(session)
        animateFocus(space: space, byID: latestSurvey)
        _ = raise(wid)
        raiseNeighbours(of: wid, pid: pid, in: space)
        windowIndicators.update(coordinator, mode: options.config.bottom)
        scheduleRefresh()
    }

    /// After a jump, a parked window's sliver can lie over a visible
    /// neighbour, since stacking follows recency, not the strip. Once the
    /// target's app is active, its raised windows go on top and other apps'
    /// land just under its front window. So raise the target app's
    /// neighbours, then the target, then the other neighbours. Apps apply
    /// raises asynchronously, so each is awaited, and the result is checked
    /// and retried.
    func raiseNeighbours(of wid: UInt32, pid: pid_t, in space: UInt64) {
        neighbourTask?.cancel()
        neighbourTask = Task { [weak self] in
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                try? await Task.sleep(for: .milliseconds(25))
            }
            for _ in 0..<3 {
                guard let self, !Task.isCancelled, self.running,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let layout = self.coordinator.sessions[space]?.state.layout,
                      let at = layout.focused.flatMap(layout.index(of:)),
                      layout.columns[at.column].slots[at.row].activeMember == wid else { return }
                let strip = Set(layout.columns.flatMap(\.slots).map(\.activeMember))
                let neighbours = layout.neighbours()
                @MainActor func stack() -> [UInt32] { Self.frontToBack().filter(strip.contains) }
                // In order: every neighbour above every parked window.
                let order = stack()
                let lowest = neighbours.compactMap { order.firstIndex(of: $0) }.max() ?? 0
                let highestParked = order.indices.first { !neighbours.contains(order[$0]) && order[$0] != wid } ?? order.count
                if lowest < highestParked { return }
                @MainActor func raise(_ id: UInt32, until done: ([UInt32]) -> Bool) async {
                    guard let element = self.references[id] else { return }
                    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                    for _ in 0..<10 where !done(stack()) { try? await Task.sleep(for: .milliseconds(10)) }
                }
                let siblings = neighbours.filter { self.pidForWindow[$0] == pid }
                for id in siblings { await raise(id) { $0.first == id } }
                if !siblings.isEmpty {
                    if let element = self.references[wid] {
                        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                    }
                    await raise(wid) { $0.first == wid }
                }
                for id in neighbours where self.pidForWindow[id] != pid {
                    await raise(id) { $0.dropFirst().first == id }
                }
            }
        }
    }

    /// Reorders the strip after a thumbnail drag and places windows in the
    /// new order; focus stays where it was.
    func moveThumbnail(_ wid: UInt32, to position: Int, in space: UInt64) {
        guard running, !paused, DisplayArrangement.currentProblem() == nil,
              coordinator.spaceForWindow[wid] == space,
              let session = coordinator.sessions[space], !session.state.interactionSuppressed,
              session.move(windowID: wid, to: position, ticket: session.ticket) else {
            windowIndicators.update(coordinator, mode: options.config.bottom, redrawSpace: space)
            return
        }
        log("moved \(wid) to tray position \(position)")
        cancelMotion(); motionFrames.removeAll()
        forceApply = true
        reveal(session)
        refresh()
        windowIndicators.update(coordinator, mode: options.config.bottom, redrawSpace: space)
    }

    func raise(_ wid: UInt32) -> Bool {
        guard let pid = pidForWindow[wid], let element = references[wid] ?? findWindow(wid, pid: pid) else { return false }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        return true
    }

    /// Executes one CLI command and returns a JSON-serialisable reply.
    public func handle(_ args: [String]) -> [String: Any] {
        if let problem = LiveCommand.validate(args) { return ["ok": false, "error": problem] }
        switch args.first {
        case "pause": return pause()
        case "resume": return resume()
        case "stop": return ["ok": true, "stop": true]
        case "status" where paused:
            let gestureConflicts = GestureConflict.checkLive(fingers: options.config.gesture.fingers)
            let gestureStatus: [String: Any] = [
                "enabled": false,
                "appGestureBlocking": (touchSource as? EventTapTouchSource)?.appGestureBlockingStatus ?? "inactive",
                "blockedBy": gestureConflicts
            ]
            return ["ok": true, "paused": true, "gesture": gestureStatus,
                    "problem": DisplayArrangement.currentProblem() ?? NSNull()]
        default: break
        }
        guard running else { return ["ok": false, "error": paused ? "paused (paperi msg resume)" : "not running"] }
        guard let verb = args.first else { return ["ok": false, "error": "empty command"] }
        let rest = Array(args.dropFirst())
        func direction(_ s: String?) -> Direction? {
            switch s { case "left": .left; case "right": .right; case "up": .up; case "down": .down; default: nil }
        }
        func fail(_ message: String) -> [String: Any] { ["ok": false, "error": message] }
        if verb != "focus" && verb != "status" { cancelMotion(); motionFrames.removeAll() }
        switch verb {
        case "status":
            return status()
        case "retile", "refresh":
            forceApply = true; refresh(); return ["ok": true]
        case "stop":
            return ["ok": true, "stop": true]
        case "focus":
            if swipe != nil { cancelMotion(); motionFrames.removeAll() }
            commandStarted = ProcessInfo.processInfo.systemUptime
            firstWriteMS = nil; finalWriteMS = nil; confirmedMS = nil
            guard let dir = direction(rest.first) else { return fail("usage: focus left|right|up|down") }
            // Focus never leaves the strip or switches Spaces: at its end (or
            // with no managed window focused) focus stays put. A managed strip bounces.
            guard let ctx = focusedContext() else {
                return ["ok": true, "changed": false, "edge": true, "managed": false]
            }
            guard let target = ctx.session.state.layout.neighbor(dir),
                  let loc = ctx.session.state.layout.index(of: target) else {
                animateFocus(space: ctx.space, byID: latestSurvey, bounce: dir)
                return ["ok": true, "changed": false, "edge": true]
            }
            let wid = ctx.session.state.layout.columns[loc.column].slots[loc.row].activeMember
            try? ctx.session.focus(windowID: wid, ownerPID: pidForWindow[wid], classification: Self.tiled, ticket: ctx.session.ticket)
            reveal(ctx.session)
            animateFocus(space: ctx.space, byID: latestSurvey)
            return ["ok": raise(wid), "windowID": wid]
        case "swipe":
            guard let dir = direction(rest.first) else { return fail("usage: swipe left|right|up|down [travel]") }
            return simulateSwipe(dir, travel: rest.count > 1 ? Double(rest[1]) ?? 1 : 1)
        case "swap", "move":
            guard let dir = direction(rest.first) else { return fail("usage: swap left|right|up|down") }
            return layoutCommand { layout, _ in layout.swap(dir) }
        case "width", "height":
            guard let sign = rest.first, sign == "+" || sign == "-" else { return fail("usage: \(verb) +|-") }
            let fraction = Double(rest.dropFirst().first ?? "") ?? 0.1
            let delta = sign == "+" ? fraction : -fraction
            if verb == "width" { return layoutCommand { layout, canvas in try layout.resizeWidth(by: delta, in: canvas, edgeMargin: self.options.gap) } }
            return layoutCommand { layout, canvas in try layout.resizeHeight(by: delta, in: canvas, gap: self.options.gap) }
        case "center":
            return layoutCommand(reveal: false) { layout, canvas in try layout.center(in: canvas, gap: self.options.gap) }
        case "split":
            return layoutCommand(reveal: false) { layout, canvas in try layout.split(in: canvas, gap: self.options.gap) }
        case "slurp":
            return layoutCommand { layout, _ in layout.slurp() }
        case "barf":
            return layoutCommand { layout, _ in layout.barf() }
        case "float":
            return toggleFloat()
        case "tray":
            return showTray() ? ["ok": true] : fail("no tray on the display under the pointer")
        default:
            return fail("unknown command \(verb)")
        }
    }

    func surveyByID() -> [UInt32: Survey] {
        var levels: [UInt32: Int] = [:]
        for row in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            if let id = row[kCGWindowNumber as String] as? UInt32 { levels[id] = row[kCGWindowLayer as String] as? Int ?? 0 }
        }
        let rows = appsToSurvey(allowlistedApps()).filter { !$0.isHidden }.flatMap { survey($0, levels: levels) }
        for row in rows { references[row.windowID] = row.element; pidForWindow[row.windowID] = row.pid }
        return Dictionary(rows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func layoutCommand(reveal shouldReveal: Bool = true,
                               _ body: (inout Layout, Rect) throws -> Void) -> [String: Any] {
        guard let ctx = focusedContext() else { return ["ok": false, "error": "no managed focused window"] }
        let canvas = ctx.session.canvas
        do {
            let changed = try ctx.session.command(frontmostPID: ctx.pid, ticket: ctx.session.ticket) { try body(&$0, canvas) }
            if changed && shouldReveal { reveal(ctx.session) }
            if changed { apply(space: ctx.space, byID: surveyByID()); rememberWidths() }
            return ["ok": true, "changed": changed]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    func toggleFloat() -> [String: Any] {
        refresh()
        guard let front = NSWorkspace.shared.frontmostApplication else { return ["ok": false, "error": "no frontmost app"] }
        let application = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return ["ok": false, "error": "no focused window"] }
        let focusedElement = value as! AXUIElement
        let wid = paperi_window_id(focusedElement)
        if userFloating.remove(wid) != nil {
            refresh()
            return ["ok": true, "floating": false, "windowID": wid]
        }
        guard coordinator.spaceForWindow[wid] != nil else { return ["ok": false, "error": "window is not managed"] }
        let members = (try? coordinator.removeContainer(containing: wid, classification: Self.tiled)) ?? []
        userFloating.formUnion(members)
        refresh()
        return ["ok": !members.isEmpty, "floating": true, "members": members]
    }

    /// Read-only: what live mode would decide for each current-Space window of
    /// the given apps (eligibility, singleton proof, native tab groups).
    /// Empty `bundleIDs` checks every app live mode would consider (config applied).
    public static func checkApps(_ bundleIDs: [String], config: LiveConfig = LiveConfig()) -> [String: Any] {
        var config = config
        if !bundleIDs.isEmpty { config.include = bundleIDs }
        let considered = NSWorkspace.shared.runningApplications.filter { Self.considered($0, config: config) }
        let pids = Set(considered.map(\.processIdentifier))
        let recorder = EventRecorder(workspaceCenter: NotificationCenter(),
                                     runningApplications: { NSWorkspace.shared.runningApplications },
                                     filter: { pids.contains($0.processIdentifier) },
                                     observeWorkspaceEvents: false, emit: { _ in })
        recorder.start(); defer { recorder.stop() }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let probe = LiveManager(options: Options(config: config))
        var levels: [UInt32: Int] = [:]
        for row in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            if let id = row[kCGWindowNumber as String] as? UInt32 { levels[id] = row[kCGWindowLayer as String] as? Int ?? 0 }
        }
        var apps: [[String: Any]] = []
        for app in probe.appsToSurvey(considered) {
            let evidence = (recorder.tabEvidence(processID: app.processIdentifier)["applications"] as? [[String: Any]])?.first ?? [:]
            let singletons = Set(NativeTabMembership.inspectSingletons(evidence))
            let groups = NativeTabMembership.inspect(evidence, requireComplete: false)
            var tabGroupChildren: [UInt32: Bool] = [:]
            if let nodes = evidence["nodes"] as? [[String: Any]], let roots = evidence["roots"] as? [Int] {
                for root in roots where nodes.indices.contains(root) {
                    guard let wid = nodes[root]["windowID"] as? UInt32,
                          let children = (nodes[root]["AXChildren"] as? [String: Any])?["nodes"] as? [Int] else { continue }
                    tabGroupChildren[wid] = children.contains { nodes.indices.contains($0) && nodes[$0]["AXRole"] as? String == "AXTabGroup" }
                }
            }
            let windows = probe.survey(app, levels: levels).map { row -> [String: Any] in
                let group = groups.first { $0.members.contains(row.windowID) }
                let decision: String
                if row.classification.reason == "user floating" { decision = "floating (config rule)" }
                else if row.classification.eligibility == .floating { decision = "floating: \(row.classification.reason)" }
                else if row.classification.eligibility != .tiled { decision = "skipped: \(row.classification.reason)" }
                else if let group { decision = "tab container \(group.members)" }
                else if singletons.contains(row.windowID) { decision = "managed as window" }
                else { decision = "withheld: tab membership unknown (use --singleton-app if it has no native tabs)" }
                return ["windowID": row.windowID, "title": Diagnostics.attribute(row.element, kAXTitleAttribute) as? String ?? "",
                        "decision": decision, "directAXTabGroup": tabGroupChildren[row.windowID] as Any? ?? NSNull()]
            }
            apps.append(["bundleID": app.bundleIdentifier ?? "", "windowsError": evidence["windowsError"] ?? NSNull(),
                         "truncated": evidence["truncated"] ?? NSNull(), "windows": windows])
        }
        return ["apps": apps, "note": "Current Space only; read-only"]
    }

    public func status() -> [String: Any] {
        let displays = coordinator.displays.map { d -> [String: Any] in
            ["uuid": d.displayUUID, "canvas": [d.canvas.x, d.canvas.y, d.canvas.width, d.canvas.height],
             "activeSpace": d.activeSpaceID ?? 0, "userSpaces": d.userSpaces]
        }
        let sessions = coordinator.sessions.filter { !$0.value.slots.isEmpty }.map { space, session -> [String: Any] in
            ["space": space, "offset": session.state.layout.offset, "focused": session.state.layout.focused ?? NSNull(),
             "suppressed": session.state.interactionSuppressed,
             "columns": session.state.layout.columns.map { column -> [String: Any] in
                 ["width": column.width, "slots": column.slots.map { slot -> [String: Any] in
                     ["id": slot.id, "members": slot.members, "active": slot.activeMember,
                      "pid": pidForWindow[slot.activeMember] ?? 0,
                      "title": references[slot.activeMember].flatMap { Diagnostics.attribute($0, kAXTitleAttribute) as? String } ?? ""]
                 }]
             }]
        }
        let gestureConflicts = GestureConflict.checkLive(fingers: options.config.gesture.fingers)
        let gestureEnabled = options.config.gesture.enabled && gestureConflicts.isEmpty
        let gestureStatus: [String: Any] = [
            "enabled": gestureEnabled,
            "appGestureBlocking": (touchSource as? EventTapTouchSource)?.appGestureBlockingStatus ?? "inactive",
                "blockedBy": gestureConflicts
        ]
        return ["ok": true, "paused": false, "apps": options.config.include?.sorted() ?? ["all regular apps"], "displays": displays, "sessions": sessions,
                "floating": userFloating.sorted(), "journaled": journal.count, "lastRefreshMS": lastRefreshMS,
                "gesture": gestureStatus,
                "performance": ["phaseMS": phaseMS, "axWriteCalls": axWriteCalls, "axWriteMS": axWriteMS,
                    "commandToFirstWriteMS": firstWriteMS as Any? ?? NSNull(),
                    "commandToFinalWriteMS": finalWriteMS as Any? ?? NSNull(),
                    "commandToConfirmedFrameMS": confirmedMS as Any? ?? NSNull(),
                    "animationTicks": motionTicks, "failedAnimationWindows": motionFailed.sorted(),
                    "lastTickMS": tickMS, "overBudgetTicks": missedTicks,
                    "swipe": swipeMetrics,
                    "animationActive": motionActive]]
    }
}
