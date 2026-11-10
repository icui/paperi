import AppKit
@preconcurrency import ApplicationServices
import PaperiBridge
import PaperiCore

/// Opt-in live manager for real windows of allowlisted applications.
///
/// Scope: every display's *active* user Space owns one scrolling strip. Windows
/// on inactive Spaces are never written. Native tab containers are admitted
/// active-first and reconciled lazily; unknown membership stays unmanaged.
/// Commands arrive through `LiveCommandServer` (`paperi msg ...`).
@MainActor public final class LiveManager {
    public struct Options: Sendable {
        public var config: LiveConfig
        public var gap: Double { config.gap ?? 8 }
        public var outerGap: Double { config.outerGap ?? 8 }
        public var restoreOnStop = true
        public var journalURL: URL
        public var verbose = false

        public init(config: LiveConfig = LiveConfig(), journalURL: URL = LiveManager.defaultJournalURL) {
            self.config = config; self.journalURL = journalURL
        }
    }

    nonisolated public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Paperi")
    }
    nonisolated public static var defaultJournalURL: URL { supportDirectory.appendingPathComponent("restore.json") }

    struct Survey {
        let windowID: UInt32
        let pid: pid_t
        let element: AXUIElement
        let classification: Classification
        let facts: WindowFacts
        let floatRequested: Bool
        let spaceID: UInt64?
        let frame: Rect?
    }

    let options: Options
    private(set) var coordinator: DisplaySpaceCoordinator
    private var recorder: EventRecorder!
    private var references: [UInt32: AXUIElement] = [:]
    private var pidForWindow: [UInt32: pid_t] = [:]
    private var journal: [UInt32: (pid: pid_t, frame: Rect)] = [:]
    private var userFloating: Set<UInt32> = []
    private var destroyedNotified: Set<UInt32> = []
    private var expected: [UInt32: (frame: Rect, at: Double)] = [:]
    private var refreshScheduled = false
    /// Apps whose AX requests timed out are skipped briefly so one hung app
    /// cannot stall management of every other app.
    private var slowUntil: [pid_t: Double] = [:]
    private var forceApply = true
    private var timer: Timer?
    private var workspaceTokens: [NSObjectProtocol] = []
    private(set) var running = false
    private var busy = false
    public private(set) var lastRefreshMS: Double = 0

    private static let tiled = WindowPolicy.classify(WindowFacts(bundleID: "live", role: "AXWindow",
        subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true, level: 0))

    public init(options: Options) {
        self.options = options
        coordinator = DisplaySpaceCoordinator(ownerPIDs: [], displays: [])
    }

    // MARK: lifecycle

    public func start() throws {
        guard AXIsProcessTrusted() else {
            // Shows the system prompt naming the responsible app (terminal/editor or Paperi.app).
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            throw LiveError.accessibility
        }
        guard !running else { return }
        try restoreStaleJournal()
        running = true
        coordinator = DisplaySpaceCoordinator(ownerPIDs: [], displays: topologies())
        recorder = EventRecorder(workspaceCenter: NSWorkspace.shared.notificationCenter,
                                 runningApplications: { NSWorkspace.shared.runningApplications },
                                 filter: { [config = options.config] app in Self.considered(app, config: config) },
                                 observeWorkspaceEvents: true,
                                 emit: { [weak self] event in self?.receive(event) })
        recorder.start()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        workspaceTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.forceApply = true; self?.scheduleRefresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Stops management, restores admission geometry and removes the journal.
    @discardableResult public func stop() -> [String: Any] {
        guard running else { return ["stopped": false] }
        running = false
        timer?.invalidate(); timer = nil
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        workspaceTokens.removeAll()
        coordinator.stop()
        let teardown = recorder.stop()
        var restored = 0, failed = 0
        if options.restoreOnStop {
            for (wid, entry) in journal {
                let element = references[wid] ?? findWindow(wid, pid: entry.pid)
                if let element, write(entry.frame, to: element) { restored += 1 } else { failed += 1 }
            }
        }
        journal.removeAll()
        try? FileManager.default.removeItem(at: options.journalURL)
        return ["stopped": true, "restored": restored, "restoreFailed": failed,
                "sourcesStillInstalled": teardown["sourcesStillInstalled"] ?? 0]
    }

    /// Restores frames left by a previous run that did not stop cleanly.
    @discardableResult public static func restore(journalURL: URL = defaultJournalURL) -> [String: Any] {
        guard let data = try? Data(contentsOf: journalURL),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ["restored": 0, "journal": "absent"]
        }
        var restored = 0, failed = 0
        for row in rows {
            guard let wid = (row["windowID"] as? NSNumber)?.uint32Value, let pid = (row["pid"] as? NSNumber)?.int32Value,
                  let f = row["frame"] as? [Double], f.count == 4 else { continue }
            let frame = Rect(x: f[0], y: f[1], width: f[2], height: f[3])
            if let element = findWindow(wid, pid: pid), write(frame, to: element) { restored += 1 } else { failed += 1 }
        }
        try? FileManager.default.removeItem(at: journalURL)
        return ["restored": restored, "restoreFailed": failed, "journal": "removed"]
    }

    private func restoreStaleJournal() throws {
        guard FileManager.default.fileExists(atPath: options.journalURL.path) else { return }
        let result = Self.restore(journalURL: options.journalURL)
        log("restored stale journal: \(result)")
    }

    // MARK: events

    private func receive(_ event: [String: Any]) {
        guard running, let name = event["event"] as? String else { return }
        if name == kAXUIElementDestroyedNotification, let wid = event["windowID"] as? UInt32, wid > 0 {
            destroyedNotified.insert(wid)
        }
        if name == kAXMovedNotification || name == kAXResizedNotification {
            // Our own writes echo back; refresh decides whether it was external.
        }
        if ["recorderReady", "recorderReconciled", "windowDiscovery", "subscriptionRetry"].contains(name) { return }
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard running, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    // MARK: discovery

    private func topologies() -> [DisplaySpaceTopology] {
        let inset = options.outerGap
        return DisplaySpaceCoordinator.liveTopologies().map { display in
            let c = display.canvas
            return DisplaySpaceTopology(displayUUID: display.displayUUID,
                canvas: Rect(x: c.x + inset, y: c.y + inset, width: c.width - 2 * inset, height: c.height - 2 * inset),
                spaces: display.spaces, activeSpaceID: display.activeSpaceID)
        }
    }

    static func considered(_ app: NSRunningApplication, config: LiveConfig) -> Bool {
        !app.isTerminated && app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            config.manages(bundleID: app.bundleIdentifier, regular: app.activationPolicy == .regular)
    }

    private func allowlistedApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { Self.considered($0, config: options.config) }
    }

    /// Apps worth an AX survey this pass: those with a normal-level window on
    /// screen (cheap window-server query) or with containers already managed.
    /// Everything else (dozens of background apps) costs nothing.
    private func appsToSurvey(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var onScreen: Set<pid_t> = []
        for row in rows where (row[kCGWindowLayer as String] as? Int ?? -1) == 0 {
            if let pid = row[kCGWindowOwnerPID as String] as? pid_t { onScreen.insert(pid) }
        }
        let managedOwners = Set(coordinator.spaceForWindow.keys.compactMap { pidForWindow[$0] })
        let now = ProcessInfo.processInfo.systemUptime
        return apps.filter { app in
            let pid = app.processIdentifier
            guard (slowUntil[pid] ?? 0) <= now else { return false }
            return onScreen.contains(pid) || managedOwners.contains(pid)
        }
    }

    private static func windowSpace(_ wid: UInt32) -> UInt64? {
        guard let spaces = paperi_copy_window_spaces(wid) as? [NSNumber], spaces.count == 1 else { return nil }
        return spaces[0].uint64Value
    }

    private func survey(_ app: NSRunningApplication, levels: [UInt32: Int]) -> [Survey] {
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        if error == .cannotComplete {
            slowUntil[pid] = ProcessInfo.processInfo.systemUptime + 5
            log("\(app.bundleIdentifier ?? "pid \(pid)") did not answer AX; skipping for 5 s")
            return []
        }
        guard error == .success, let windows = value as? [AXUIElement] else { return [] }
        let bundleID = app.bundleIdentifier ?? ""
        return windows.compactMap { ref in
            AXUIElementSetMessagingTimeout(ref, 0.2)
            let wid = paperi_window_id(ref)
            guard wid > 0 else { return nil }
            let parent = Diagnostics.attribute(ref, kAXParentAttribute)
            var move = DarwinBoolean(false), resize = DarwinBoolean(false)
            let moveResult = AXUIElementIsAttributeSettable(ref, kAXPositionAttribute as CFString, &move)
            let resizeResult = AXUIElementIsAttributeSettable(ref, kAXSizeAttribute as CFString, &resize)
            let facts = WindowFacts(bundleID: app.bundleIdentifier ?? "",
                role: Diagnostics.attribute(ref, kAXRoleAttribute) as? String,
                subrole: Diagnostics.attribute(ref, kAXSubroleAttribute) as? String,
                isRoot: parent.map { CFEqual($0, application) },
                movable: moveResult == .success ? move.boolValue : nil,
                resizable: resizeResult == .success ? resize.boolValue : nil,
                fullscreen: Diagnostics.attribute(ref, "AXFullScreen") as? Bool ?? false,
                minimized: Diagnostics.attribute(ref, kAXMinimizedAttribute) as? Bool,
                level: levels[wid], hasFullScreenButton: Self.hasFullScreenButton(ref))
            let title = (options.config.float.isEmpty && options.config.tile.isEmpty) ? nil
                : Diagnostics.attribute(ref, kAXTitleAttribute) as? String
            let ruleFloat = !options.config.float.isEmpty && options.config.floats(bundleID: bundleID, title: title)
            let ruleTile = !options.config.tile.isEmpty && options.config.tiles(bundleID: bundleID, title: title)
            let classification = WindowPolicy.classify(facts, userFloating: ruleFloat || userFloating.contains(wid),
                                                       forceTile: ruleTile)
            return Survey(windowID: wid, pid: pid, element: ref, classification: classification, facts: facts,
                          floatRequested: ruleFloat || userFloating.contains(wid),
                          spaceID: Self.windowSpace(wid), frame: Diagnostics.frame(ref))
        }
    }

    /// Absent attribute → false; read failure (timeout) → unknown.
    private static func hasFullScreenButton(_ window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(window, "AXFullScreenButton" as CFString, &value) {
        case .success: return value != nil
        case .noValue, .attributeUnsupported: return false
        default: return nil
        }
    }

    // MARK: reconciliation

    /// One reconciliation pass: displays → destruction → Space moves → tab
    /// topology → admissions → focus → observed resizes → effects.
    public func refresh() {
        guard running, !busy else { return }
        busy = true; defer { busy = false }
        let started = ProcessInfo.processInfo.systemUptime
        let displays = topologies()
        coordinator.updateDisplays(displays)
        let activeSpaces = Set(displays.compactMap(\.activeSpaceID))

        let cgRows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var levels: [UInt32: Int] = [:]
        for row in cgRows {
            if let id = row[kCGWindowNumber as String] as? UInt32 { levels[id] = row[kCGWindowLayer as String] as? Int ?? 0 }
        }
        let apps = allowlistedApps()
        let livePIDs = Set(apps.map(\.processIdentifier))
        for app in apps { coordinator.addOwner(app.processIdentifier) }

        // 1. Destruction: native notification, window-server absence, or owner exit.
        let managed = Set(coordinator.spaceForWindow.keys)
        let gone = managed.filter { wid in
            destroyedNotified.contains(wid) || levels[wid] == nil || pidForWindow[wid].map { !livePIDs.contains($0) } ?? true
        }
        destroyedNotified.removeAll()
        if !gone.isEmpty { removeMembers(gone) }

        // 2. Survey allowlisted apps.
        var surveys: [pid_t: [Survey]] = [:]
        for app in appsToSurvey(apps) where !app.isHidden { surveys[app.processIdentifier] = survey(app, levels: levels) }
        for app in apps where app.isHidden {
            // Hidden apps leave the strip and return at the focused position when shown.
            let windows = coordinator.spaceForWindow.keys.filter { pidForWindow[$0] == app.processIdentifier }
            for wid in windows where coordinator.spaceForWindow[wid] != nil {
                _ = try? coordinator.removeContainer(containing: wid, classification: Self.tiled)
            }
        }
        for (pid, rows) in surveys {
            for row in rows { references[row.windowID] = row.element; pidForWindow[row.windowID] = pid }
        }
        let byID = Dictionary(surveys.values.flatMap { $0 }.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })

        // 3. Definitive state changes (minimized, fullscreen, floated by the
        // user or a rule) leave the strip. Transient metadata, e.g. a sheet
        // making its parent temporarily non-movable, keeps the slot.
        for (wid, row) in byID where coordinator.spaceForWindow[wid] != nil &&
            (row.facts.minimized == true || row.facts.fullscreen == true || row.floatRequested) {
            if isActiveRepresentative(wid) { _ = try? coordinator.removeContainer(containing: wid, classification: Self.tiled) }
        }

        // 4. Representatives that changed Space (Mission Control drag, display drag).
        for (wid, row) in byID {
            guard let current = coordinator.spaceForWindow[wid], let space = row.spaceID, space != current,
                  isActiveRepresentative(wid), coordinator.sessions[space] != nil else { continue }
            if (try? coordinator.transferContainer(containing: wid, to: space, classification: Self.tiled)) != nil {
                forceApply = true
                log("container of \(wid) followed to Space \(space)")
            }
        }

        // 5. Per-app tab topology and admission on active Spaces.
        for app in apps where !app.isHidden {
            let pid = app.processIdentifier
            guard let rows = surveys[pid] else { continue }
            let singletonApp = app.bundleIdentifier.map(options.config.singleton.contains) == true
            let relevant = rows.contains { row in row.spaceID.map(activeSpaces.contains) == true &&
                (row.classification.eligibility == .tiled || coordinator.spaceForWindow[row.windowID] != nil) }
            guard relevant else { continue }
            let evidence = singletonApp ? nil : (recorder.tabEvidence(processID: pid)["applications"] as? [[String: Any]])?.first
            for space in activeSpaces {
                guard let session = coordinator.sessions[space] else { continue }
                let candidates = Set(rows.filter {
                    $0.spaceID == space && $0.classification.eligibility == .tiled && coordinator.spaceForWindow[$0.windowID] == nil
                }.map(\.windowID))
                let mine = Set(session.slots.keys.filter { pidForWindow[$0] == pid })
                if let evidence, !mine.isEmpty,
                   let parts = NativeTabTopology.inspect(evidence, managed: mine, destroyed: [], additions: candidates,
                                                         allowLazyUnvisited: true) {
                    let slots = session.state.layout.columns.flatMap(\.slots)
                    let others = LiveReconciliation.identityPartitions(slots, excluding: mine)
                    let admitted = Set(parts.flatMap(\.members)).subtracting(mine)
                    if (try? coordinator.reconcileTabs(in: space, partitions: parts + others, destroyed: [],
                                                       classification: Self.tiled, admitted: admitted)) == true {
                        log("tabs reconciled on Space \(space): \(parts.map(\.members))")
                    }
                }
                var remaining = candidates.filter { coordinator.spaceForWindow[$0] == nil }
                if singletonApp {
                    for wid in remaining.sorted() { admitSingleton(wid, pid: pid, space: space, byID: byID) }
                    continue
                }
                guard let evidence else { continue }
                for group in NativeTabMembership.inspect(evidence, requireComplete: false)
                where remaining.contains(group.active) && group.members.allSatisfy({ coordinator.spaceForWindow[$0] == nil }) {
                    if (try? coordinator.admitTabs(members: group.members, active: group.active, ownerPID: pid,
                                                   spaceID: space, classification: Self.tiled, allowActiveOnly: true)) == true {
                        remember(group.active, pid: pid, frame: byID[group.active]?.frame)
                        remaining.subtract(group.members)
                        log("admitted tab container \(group.members) active \(group.active) on Space \(space)")
                    }
                }
                for wid in NativeTabMembership.inspectSingletons(evidence) where remaining.contains(wid) {
                    admitSingleton(wid, pid: pid, space: space, byID: byID)
                }
            }
        }

        // 6. Focus: only an allowlisted, managed representative enables commands.
        let front = NSWorkspace.shared.frontmostApplication
        var focusedWindow: UInt32?
        if let front, livePIDs.contains(front.processIdentifier) {
            let application = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            if let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = value as! AXUIElement
                focusedWindow = paperi_window_id(element)
            }
        }
        for (space, session) in coordinator.sessions where activeSpaces.contains(space) {
            let owned = focusedWindow.flatMap { session.slots[$0] != nil ? $0 : nil }
            let classification = owned != nil ? Self.tiled : WindowPolicy.classify(WindowFacts(bundleID: "foreign"))
            try? session.focus(windowID: owned, ownerPID: owned != nil ? front?.processIdentifier : nil,
                               classification: classification, ticket: session.ticket)
            // Removals, insertions and focus changes can leave the focused
            // column partly off-canvas; reveal is minimal and idempotent.
            reveal(session)
        }

        // 7. Adopt user width changes on active representatives.
        let now = ProcessInfo.processInfo.systemUptime
        for space in activeSpaces {
            guard let session = coordinator.sessions[space],
                  let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { continue }
            for placement in placements {
                guard let exp = expected[placement.windowID], now - exp.at > 0.6,
                      let frame = byID[placement.windowID]?.frame, frame.isValid,
                      abs(frame.width - exp.frame.width) > 2, let pid = pidForWindow[placement.windowID] else { continue }
                expected[placement.windowID] = (frame, now)
                if (try? session.resize(windowID: placement.windowID, ownerPID: pid, spaceID: space,
                                        width: frame.width, classification: Self.tiled, ticket: session.ticket)) == true {
                    log("adopted width \(Int(frame.width)) for \(placement.windowID)")
                }
            }
        }

        // 8. Effects.
        for space in activeSpaces { apply(space: space, byID: byID) }
        forceApply = false
        lastRefreshMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    }

    private func isActiveRepresentative(_ wid: UInt32) -> Bool {
        guard let session = coordinator.session(containing: wid), let slot = session.slots[wid],
              let loc = session.state.layout.index(of: slot) else { return false }
        return session.state.layout.columns[loc.column].slots[loc.row].activeMember == wid
    }

    private func admitSingleton(_ wid: UInt32, pid: pid_t, space: UInt64, byID: [UInt32: Survey]) {
        guard let row = byID[wid], row.classification.eligibility == .tiled else { return }
        if (try? coordinator.insertSingleton(windowID: wid, ownerPID: pid, spaceID: space, classification: row.classification)) == true {
            remember(wid, pid: pid, frame: row.frame)
            log("admitted window \(wid) on Space \(space)")
        }
    }

    private func removeMembers(_ gone: Set<UInt32>) {
        let spaces = Set(gone.compactMap { coordinator.spaceForWindow[$0] })
        for space in spaces {
            guard let session = coordinator.sessions[space] else { continue }
            let slots = session.state.layout.columns.flatMap(\.slots)
            let parts = LiveReconciliation.partitions(removing: gone, from: slots)
            let destroyed = Set(session.slots.keys).intersection(gone)
            _ = try? coordinator.reconcileTabs(in: space, partitions: parts, destroyed: destroyed, classification: Self.tiled)
        }
        for wid in gone {
            references.removeValue(forKey: wid); pidForWindow.removeValue(forKey: wid)
            expected.removeValue(forKey: wid)
            if journal.removeValue(forKey: wid) != nil { persistJournal() }
        }
        log("removed destroyed members \(gone.sorted())")
    }

    private func reveal(_ session: ScopedLayoutSession) {
        var layout = session.state.layout
        if (try? layout.reveal(in: session.canvas, gap: options.gap)) == true {
            session.setOffset(layout.offset, ticket: session.ticket)
        }
    }

    // MARK: effects

    private func displayBounds() -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "Main"
            result[uuid] = CGDisplayBounds(id)
        }
        return result
    }

    private var applied: [UInt64: [Placement]] = [:]

    private func apply(space: UInt64, byID: [UInt32: Survey]) {
        guard let session = coordinator.sessions[space],
              let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { return }
        if !forceApply, applied[space] == placements { return }
        let bounds = displayBounds()
        let display = coordinator.display(forSpace: space)
        let own = display.flatMap { bounds[$0.displayUUID] } ?? CGDisplayBounds(CGMainDisplayID())
        let others = bounds.filter { $0.key != display?.displayUUID }.map(\.value)
        var allConfirmed = true
        for placement in placements {
            let wid = placement.windowID
            guard let element = references[wid], let row = byID[wid], row.spaceID == space else { allConfirmed = false; continue }
            // Do not fight a window that is temporarily not movable (open sheet).
            guard row.classification.eligibility == .tiled else { allConfirmed = false; continue }
            let target = LiveReconciliation.park(placement.frame, canvas: session.canvas, display: own, otherDisplays: others)
            if let frame = row.frame, matches(frame, target) { expected[wid] = (target, ProcessInfo.processInfo.systemUptime); continue }
            session.expect(windowID: wid, frame: target, now: ProcessInfo.processInfo.systemUptime, ticket: session.ticket)
            expected[wid] = (target, ProcessInfo.processInfo.systemUptime)
            if !write(target, to: element) { allConfirmed = false }
        }
        if allConfirmed { applied[space] = placements } else { applied.removeValue(forKey: space) }
    }

    private func matches(_ a: Rect, _ b: Rect) -> Bool {
        zip([a.x, a.y, a.width, a.height], [b.x, b.y, b.width, b.height]).allSatisfy { abs($0 - $1) <= 2 }
    }

    @discardableResult private static func write(_ frame: Rect, to element: AXUIElement) -> Bool {
        var point = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return false }
        // Size, position, size: shrinking first avoids edge clamping; the
        // second size handles apps that clamp size against the old position.
        var ok = true
        for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)] {
            ok = AXUIElementSetAttributeValue(element, name as CFString, value) == .success && ok
        }
        return ok
    }
    private func write(_ frame: Rect, to element: AXUIElement) -> Bool { Self.write(frame, to: element) }

    private static func findWindow(_ wid: UInt32, pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return (Diagnostics.attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [])
            .first { paperi_window_id($0) == wid }
    }
    private func findWindow(_ wid: UInt32, pid: pid_t) -> AXUIElement? { Self.findWindow(wid, pid: pid) }

    // MARK: journal

    private func remember(_ wid: UInt32, pid: pid_t, frame: Rect?) {
        guard let frame, frame.isValid, journal[wid] == nil else { return }
        journal[wid] = (pid, frame)
        persistJournal()
    }

    private func persistJournal() {
        let rows: [[String: Any]] = journal.map { wid, entry in
            ["windowID": wid, "pid": entry.pid, "frame": [entry.frame.x, entry.frame.y, entry.frame.width, entry.frame.height]]
        }
        do {
            try FileManager.default.createDirectory(at: options.journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            try data.write(to: options.journalURL, options: .atomic)
        } catch { log("cannot persist restore journal: \(error)") }
    }

    private func log(_ message: String) {
        guard options.verbose else { return }
        FileHandle.standardError.write(Data("[paperi] \(message)\n".utf8))
    }

    // MARK: commands

    public enum LiveError: Error, CustomStringConvertible {
        case accessibility
        public var description: String { "Accessibility trust is required (System Settings › Privacy & Security › Accessibility)" }
    }

    private func focusedContext() -> (session: ScopedLayoutSession, space: UInt64, pid: pid_t, window: UInt32)? {
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

    private func raise(_ wid: UInt32) -> Bool {
        guard let pid = pidForWindow[wid], let element = references[wid] ?? findWindow(wid, pid: pid) else { return false }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        return true
    }

    /// Executes one CLI command and returns a JSON-serialisable reply.
    public func handle(_ args: [String]) -> [String: Any] {
        guard running else { return ["ok": false, "error": "not running"] }
        guard let verb = args.first else { return ["ok": false, "error": "empty command"] }
        let rest = Array(args.dropFirst())
        func direction(_ s: String?) -> Direction? {
            switch s { case "left": .left; case "right": .right; case "up": .up; case "down": .down; default: nil }
        }
        func fail(_ message: String) -> [String: Any] { ["ok": false, "error": message] }
        switch verb {
        case "status":
            return status()
        case "retile", "refresh":
            forceApply = true; refresh(); return ["ok": true]
        case "stop":
            return ["ok": true, "stop": true]
        case "focus":
            guard let dir = direction(rest.first) else { return fail("usage: focus left|right|up|down") }
            // As in the user's Hammerspoon focusWindowByTwo: with no managed
            // focused window, or at the strip edge, J/K switch to the adjacent Space.
            guard let ctx = focusedContext() else {
                return dir == .left || dir == .right ? switchSpace(dir) : fail("no managed focused window")
            }
            guard let target = ctx.session.state.layout.neighbor(dir),
                  let loc = ctx.session.state.layout.index(of: target) else {
                return dir == .left || dir == .right ? switchSpace(dir) : ["ok": true, "changed": false, "edge": true]
            }
            let wid = ctx.session.state.layout.columns[loc.column].slots[loc.row].activeMember
            try? ctx.session.focus(windowID: wid, ownerPID: pidForWindow[wid], classification: Self.tiled, ticket: ctx.session.ticket)
            reveal(ctx.session)
            apply(space: ctx.space, byID: surveyByID())
            return ["ok": raise(wid), "windowID": wid]
        case "swap", "move":
            guard let dir = direction(rest.first) else { return fail("usage: swap left|right|up|down") }
            return layoutCommand { layout, _ in layout.swap(dir) }
        case "width", "height":
            guard let sign = rest.first, sign == "+" || sign == "-" else { return fail("usage: \(verb) +|-") }
            let fraction = Double(rest.dropFirst().first ?? "") ?? 0.1
            let delta = sign == "+" ? fraction : -fraction
            if verb == "width" { return layoutCommand { layout, canvas in try layout.resizeWidth(by: delta, in: canvas) } }
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
        case "space":
            guard let n = rest.first.flatMap(Int.init) else { return fail("usage: space N") }
            return moveToSpace(n)
        default:
            return fail("unknown command \(verb)")
        }
    }

    /// Posts the system "Move left/right a space" shortcut (Control–arrow) when
    /// an adjacent Space exists on the display showing the active Space.
    private func switchSpace(_ direction: Direction) -> [String: Any] {
        let active = paperi_active_space()
        guard let display = coordinator.displays.first(where: { $0.spaces.contains { $0.id == active } }),
              let index = display.spaces.firstIndex(where: { $0.id == active }) else {
            return ["ok": false, "error": "active Space unknown"]
        }
        let next = index + (direction == .left ? -1 : 1)
        guard display.spaces.indices.contains(next) else { return ["ok": true, "changed": false, "edge": true] }
        let key: CGKeyCode = direction == .left ? 123 : 124
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            event?.post(tap: .cghidEventTap)
        }
        return ["ok": true, "switchedSpace": true, "from": active, "toward": display.spaces[next].id]
    }

    private func surveyByID() -> [UInt32: Survey] {
        var levels: [UInt32: Int] = [:]
        for row in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            if let id = row[kCGWindowNumber as String] as? UInt32 { levels[id] = row[kCGWindowLayer as String] as? Int ?? 0 }
        }
        let rows = appsToSurvey(allowlistedApps()).filter { !$0.isHidden }.flatMap { survey($0, levels: levels) }
        for row in rows { references[row.windowID] = row.element; pidForWindow[row.windowID] = row.pid }
        return Dictionary(rows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func layoutCommand(reveal shouldReveal: Bool = true,
                               _ body: (inout Layout, Rect) throws -> Void) -> [String: Any] {
        guard let ctx = focusedContext() else { return ["ok": false, "error": "no managed focused window"] }
        let canvas = ctx.session.canvas
        do {
            let changed = try ctx.session.command(frontmostPID: ctx.pid, ticket: ctx.session.ticket) { try body(&$0, canvas) }
            if changed && shouldReveal { reveal(ctx.session) }
            if changed { apply(space: ctx.space, byID: surveyByID()) }
            return ["ok": true, "changed": changed]
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    private func toggleFloat() -> [String: Any] {
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

    private func moveToSpace(_ number: Int) -> [String: Any] {
        guard let ctx = focusedContext() else { return ["ok": false, "error": "no managed focused window"] }
        guard let destination = coordinator.numberedUserSpace(number) else { return ["ok": false, "error": "no user Space \(number)"] }
        guard destination != ctx.space else { return ["ok": true, "changed": false] }
        guard let element = references[ctx.window],
              let title = Diagnostics.attribute(element, kAXTitleAttribute) as? String, !title.isEmpty else {
            return ["ok": false, "error": "Mission Control transfer needs a titled window"]
        }
        guard let destinationDisplay = coordinator.display(forSpace: destination),
              let sourceDisplay = coordinator.display(forSpace: ctx.space) else { return ["ok": false, "error": "unknown display"] }
        var report: [String: Any] = ["ok": false, "windowID": ctx.window, "from": ctx.space, "to": destination]
        if destinationDisplay.displayUUID != sourceDisplay.displayUUID {
            // Cross-display: place the window on the destination display's
            // canvas; the window server moves it to that display's active Space.
            let canvas = destinationDisplay.canvas
            let width = min(canvas.width, Diagnostics.frame(element)?.width ?? canvas.width / 2)
            _ = write(Rect(x: canvas.x + (canvas.width - width) / 2, y: canvas.y, width: width, height: canvas.height), to: element)
            var landed: UInt64?
            for _ in 0..<20 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                landed = Self.windowSpace(ctx.window)
                if landed == destinationDisplay.activeSpaceID { break }
            }
            report["displayMove"] = landed.map { $0 as Any } ?? NSNull()
            if landed != destination {
                guard landed == destinationDisplay.activeSpaceID else {
                    report["error"] = "window did not reach destination display"; return report
                }
                _ = try? coordinator.transferContainer(containing: ctx.window, to: landed!, classification: Self.tiled)
            }
        }
        if Self.windowSpace(ctx.window) != destination {
            let origin = displayBounds()[destinationDisplay.displayUUID]?.origin ?? .zero
            let result = SpaceTransfer.moveWindowViaMissionControl(windowID: ctx.window, expectedTitle: title,
                                                                   toSpace: destination, screenOrigin: origin)
            report["missionControl"] = result
            guard result["transferred"] as? Bool == true else {
                report["error"] = result["failure"] ?? "Mission Control transfer unconfirmed"; return report
            }
        }
        _ = try? coordinator.transferContainer(containing: ctx.window, to: destination, classification: Self.tiled)
        forceApply = true
        refresh()
        _ = raise(ctx.window)
        report["ok"] = coordinator.spaceForWindow[ctx.window] == destination
        return report
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
        return ["ok": true, "apps": options.config.include?.sorted() ?? ["all regular apps"], "displays": displays, "sessions": sessions,
                "floating": userFloating.sorted(), "journaled": journal.count, "lastRefreshMS": lastRefreshMS]
    }
}
