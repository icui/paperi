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

    public private(set) var options: Options
    public private(set) var paused = false
    private(set) var coordinator: DisplaySpaceCoordinator
    private var recorder: EventRecorder!
    private var references: [UInt32: AXUIElement] = [:]
    private var pidForWindow: [UInt32: pid_t] = [:]
    private var journal: [UInt32: (pid: pid_t, frame: Rect)] = [:]
    private var userFloating: Set<UInt32> = []
    private var destroyedNotified: Set<UInt32> = []
    private var expected: [UInt32: (frame: Rect, at: Double)] = [:]
    /// Managed window the user is dragging (moved while the left button is
    /// down). It is not written until mouse up, so it follows the pointer.
    /// While the pointer is over a neighbouring window (adjacent column or
    /// same stack) it is highlighted (`hovered`); releasing there swaps them.
    private struct Drag { let windowID: UInt32; let space: UInt64; let targets: [SwapTarget]; var hovered: SwapTarget? }
    private var drag: Drag?
    private var dragging: UInt32? { drag?.windowID }
    private var dragTimer: Timer?
    private let highlight = SwapHighlight()
    private var mouseUpWatch = false
    /// Last off-slot frame acted on per window, so an app that clamps its
    /// position is rewritten once rather than on every refresh.
    private var displaced: [UInt32: Rect] = [:]
    private var refreshScheduled = false
    /// Apps whose AX requests timed out are skipped briefly so one hung app
    /// cannot stall management of every other app.
    private var slowUntil: [pid_t: Double] = [:]
    private var forceApply = true
    /// After an active-Space change, refreshes re-check real frames for a short
    /// while: macOS and apps (e.g. leaving a fullscreen Space) may move
    /// off-canvas windows on screen once their Space is shown again.
    private var forceUntil: Double = 0
    /// Last column width of every managed member, kept after the window leaves
    /// the strip (minimize, hide, fullscreen, float) so it returns at that
    /// width, as in PaperWM.
    private var preferredWidth: [UInt32: Double] = [:]
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

    /// `resuming` keeps the in-memory/persisted journal from a pause or
    /// reload instead of treating it as a crash leftover.
    public func start(resuming: Bool = false) throws {
        guard AXIsProcessTrusted() else {
            // Shows the system prompt naming the responsible app (terminal/editor or Paperi.app).
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            throw LiveError.accessibility
        }
        guard !running else { return }
        if !resuming { try restoreStaleJournal() }
        running = true; paused = false
        references.removeAll(); pidForWindow.removeAll(); expected.removeAll(); applied.removeAll()
        endDrag(); displaced.removeAll()
        destroyedNotified.removeAll(); slowUntil.removeAll(); forceApply = true
        coordinator = DisplaySpaceCoordinator(ownerPIDs: [], displays: topologies())
        recorder = EventRecorder(workspaceCenter: NSWorkspace.shared.notificationCenter,
                                 runningApplications: { NSWorkspace.shared.runningApplications },
                                 filter: { [config = options.config] app in Self.considered(app, config: config) },
                                 observeWorkspaceEvents: true,
                                 emit: { [weak self] event in self?.receive(event) })
        recorder.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        })
        for name in [NSWorkspace.didActivateApplicationNotification,
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

    /// Leaves windows where they are; `resume` re-admits them and a later
    /// stop still restores their original (pre-Paperi) frames.
    @discardableResult public func pause() -> [String: Any] {
        guard running else { return ["ok": paused, "paused": paused] }
        stop(restore: false, keepJournal: true)
        paused = true
        return ["ok": true, "paused": true]
    }

    @discardableResult public func resume() -> [String: Any] {
        guard paused else { return ["ok": running, "paused": false] }
        do { try start(resuming: true) } catch { return ["ok": false, "error": "\(error)"] }
        return ["ok": true, "paused": false]
    }

    /// Applies a new configuration without restoring or losing original frames.
    @discardableResult public func reload(_ config: LiveConfig) -> [String: Any] {
        let wasPaused = paused
        if running { stop(restore: false, keepJournal: true) }
        options.config = config
        if wasPaused { paused = true; return ["ok": true, "paused": true] }
        do { try start(resuming: true) } catch { return ["ok": false, "error": "\(error)"] }
        return ["ok": true]
    }

    public var managedWindowCount: Int { coordinator.spaceForWindow.count }

    /// Stops management, restores admission geometry and removes the journal.
    @discardableResult public func stop(restore: Bool? = nil, keepJournal: Bool = false) -> [String: Any] {
        if paused && !keepJournal {
            // Paused: nothing is running, but the journal still holds originals.
            paused = false
            return restoreJournal(restore ?? options.restoreOnStop)
        }
        guard running else { return ["stopped": false] }
        running = false
        timer?.invalidate(); timer = nil; endDrag()
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        workspaceTokens.removeAll()
        coordinator.stop()
        let teardown = recorder.stop()
        if keepJournal { return ["stopped": true, "sourcesStillInstalled": teardown["sourcesStillInstalled"] ?? 0] }
        var result = restoreJournal(restore ?? options.restoreOnStop)
        result["stopped"] = true
        result["sourcesStillInstalled"] = teardown["sourcesStillInstalled"] ?? 0
        return result
    }

    private func restoreJournal(_ restore: Bool) -> [String: Any] {
        var restored = 0, failed = 0
        if restore {
            for (wid, entry) in journal {
                let element = references[wid] ?? findWindow(wid, pid: entry.pid)
                if let element, write(entry.frame, to: element) { restored += 1 } else { failed += 1 }
            }
        }
        journal.removeAll()
        try? FileManager.default.removeItem(at: options.journalURL)
        return ["restored": restored, "restoreFailed": failed]
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

    private func activeSpaceChanged() {
        forceUntil = ProcessInfo.processInfo.systemUptime + 1.6
        scheduleRefresh()
        // The switch animation and app re-activation settle over ~1 s.
        for delay in [0.35, 0.8, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// Follows the pointer during a drag: highlights the neighbour under it and,
    /// on mouse up, finishes the drag and places the window.
    private func trackDrag() {
        guard running, var current = drag else { endDrag(); return }
        if NSEvent.pressedMouseButtons & 1 == 0 { finishDrag(); refresh(); return }
        let pointer = NSEvent.mouseLocation
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let hit = current.targets.first { $0.contains(x: pointer.x, y: primaryHeight - pointer.y) }
        guard hit != current.hovered else { return }
        current.hovered = hit; drag = current
        if let hit, let session = coordinator.sessions[current.space],
           let loc = session.state.layout.index(of: hit.slotID) {
            let target = session.state.layout.columns[loc.column].slots[loc.row].activeMember
            highlight.show(hit.region, color: options.config.swapHighlightColor, above: target)
        } else {
            highlight.hide()
        }
    }

    /// Swaps with the hovered window, if any, and forces a placement pass.
    private func finishDrag() {
        guard let current = drag else { endDrag(); return }
        endDrag()
        forceApply = true
        guard let target = current.hovered, let session = coordinator.sessions[current.space] else { return }
        if session.swapSlots(windowID: current.windowID, with: target.slotID, ticket: session.ticket) {
            log("swapped \(current.windowID) with slot \(target.slotID) after drag")
        }
    }

    private func endDrag() {
        drag = nil
        dragTimer?.invalidate(); dragTimer = nil
        highlight.hide()
    }

    /// No AX event may follow a release, so poll for mouse up and refresh once
    /// to apply what was deferred (step 8).
    private func refreshOnMouseUp() {
        guard !mouseUpWatch else { return }
        mouseUpWatch = true
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.running, NSEvent.pressedMouseButtons & 1 != 0 { poll(); return }
                    self.mouseUpWatch = false
                    self.scheduleRefresh()
                }
            }
        }
        poll()
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
        // While the left button is held (moving, resizing, or just a click in
        // progress) the pass only observes: state is reconciled and drags are
        // detected, but nothing scrolls, reflows or is written until mouse up.
        let mouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let displays = topologies()
        coordinator.updateDisplays(displays)
        let activeSpaces = Set(displays.compactMap(\.activeSpaceID))
        // A Space that is not shown may have its windows moved by the system;
        // verify its frames again when it becomes active.
        for space in applied.keys where !activeSpaces.contains(space) { applied.removeValue(forKey: space) }

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
        preferredWidth = preferredWidth.filter { levels[$0.key] != nil }

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
                    let width = admissionWidth(group.members, active: group.active, byID: byID, canvas: session.canvas)
                    if (try? coordinator.admitTabs(members: group.members, active: group.active, ownerPID: pid,
                                                   spaceID: space, classification: Self.tiled, allowActiveOnly: true,
                                                   width: width)) == true {
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
        // An app activated without a click (notification, Dock, ⌘-Tab, `open`)
        // whose windows are all parked off-canvas often has no focused or main
        // window. Treat its frontmost managed window as focused so the strip
        // reveals it, and raise it after placement so it takes key focus.
        var raiseAfterApply: UInt32?
        if let front, livePIDs.contains(front.processIdentifier), focusedWindow == nil {
            let pid = front.processIdentifier
            // CGWindowList rows are ordered front to back.
            focusedWindow = cgRows.lazy.compactMap { row -> UInt32? in
                guard row[kCGWindowOwnerPID as String] as? pid_t == pid,
                      let id = row[kCGWindowNumber as String] as? UInt32,
                      let space = self.coordinator.spaceForWindow[id], activeSpaces.contains(space),
                      self.isActiveRepresentative(id) else { return nil }
                return id
            }.first
            raiseAfterApply = focusedWindow
        }
        for (space, session) in coordinator.sessions where activeSpaces.contains(space) {
            let owned = focusedWindow.flatMap { session.slots[$0] != nil ? $0 : nil }
            let classification = owned != nil ? Self.tiled : WindowPolicy.classify(WindowFacts(bundleID: "foreign"))
            try? session.focus(windowID: owned, ownerPID: owned != nil ? front?.processIdentifier : nil,
                               classification: classification, ticket: session.ticket)
            // Removals, insertions and focus changes can leave the focused
            // column partly off-canvas; reveal is minimal and idempotent.
            if !mouseDown { reveal(session) }
        }

        // 7. Adopt user width changes on active representatives (on mouse up).
        let now = ProcessInfo.processInfo.systemUptime
        for space in activeSpaces {
            guard let session = coordinator.sessions[space],
                  let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { continue }
            for placement in placements {
                guard let exp = expected[placement.windowID], now - exp.at > 0.6,
                      let frame = byID[placement.windowID]?.frame, frame.isValid,
                      abs(frame.width - exp.frame.width) > 2, let pid = pidForWindow[placement.windowID] else { continue }
                if mouseDown { continue }
                expected[placement.windowID] = (frame, now)
                let width = min(frame.width, maxColumnWidth(session.canvas))
                // Wider than the cap: the window is written back to the capped width.
                if width < frame.width - 2 { forceApply = true }
                if (try? session.resize(windowID: placement.windowID, ownerPID: pid, spaceID: space,
                                        width: width, classification: Self.tiled, ticket: session.ticket)) == true {
                    log("adopted width \(Int(width)) for \(placement.windowID)")
                }
            }
        }

        // 7b. User moves. A window moved without a drag is put back. A drag is
        // tracked until mouse up (trackDrag): it swaps with a neighbouring
        // column only if released over it, then snaps into its slot.
        if !mouseDown, drag != nil { finishDrag() }
        if !forceApply, now >= forceUntil {
            for space in activeSpaces {
                guard let session = coordinator.sessions[space],
                      let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { continue }
                for placement in placements {
                    let wid = placement.windowID
                    guard let exp = expected[wid], now - exp.at > 0.6,
                          let frame = byID[wid]?.frame, frame.isValid, abs(frame.width - exp.frame.width) <= 2,
                          abs(frame.x - exp.frame.x) > 2 || abs(frame.y - exp.frame.y) > 2,
                          dragging == wid || displaced[wid] != frame else { continue }
                    displaced[wid] = frame
                    applied.removeValue(forKey: space)
                    guard mouseDown, drag == nil,
                          let targets = try? session.state.layout.swapTargets(slotID: placement.slotID, in: session.canvas,
                                                                             gap: options.gap) else { continue }
                    drag = Drag(windowID: wid, space: space, targets: targets, hovered: nil)
                    dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.trackDrag() }
                    }
                }
            }
        }

        // 8. Effects, deferred to mouse up (no AX event may follow the release).
        if mouseDown {
            refreshOnMouseUp()
        } else {
            for space in activeSpaces { apply(space: space, byID: byID) }
            forceApply = false
            if let wid = raiseAfterApply, let element = references[wid] {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                log("raised \(wid): app activated without a focused window")
            }
        }
        rememberWidths()
        lastRefreshMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    }

    private func isActiveRepresentative(_ wid: UInt32) -> Bool {
        guard let session = coordinator.session(containing: wid), let slot = session.slots[wid],
              let loc = session.state.layout.index(of: slot) else { return false }
        return session.state.layout.columns[loc.column].slots[loc.row].activeMember == wid
    }

    private func admitSingleton(_ wid: UInt32, pid: pid_t, space: UInt64, byID: [UInt32: Survey]) {
        guard let row = byID[wid], row.classification.eligibility == .tiled,
              let canvas = coordinator.sessions[space]?.canvas else { return }
        if (try? coordinator.insertSingleton(windowID: wid, ownerPID: pid, spaceID: space, classification: row.classification,
                                             width: admissionWidth([wid], active: wid, byID: byID, canvas: canvas))) == true {
            remember(wid, pid: pid, frame: row.frame)
            log("admitted window \(wid) on Space \(space)")
        }
    }

    /// Remembered width of any member, else the active window's own width,
    /// capped so neighbouring edges and margins stay visible.
    private func admissionWidth(_ members: [UInt32], active: UInt32, byID: [UInt32: Survey], canvas: Rect) -> Double? {
        let own = ([active] + members).lazy.compactMap({ self.preferredWidth[$0] }).first
            ?? byID[active]?.frame.flatMap { $0.isValid ? $0.width : nil }
        return own.map { min($0, maxColumnWidth(canvas)) }
    }

    private func maxColumnWidth(_ canvas: Rect) -> Double {
        Layout.maxColumnWidth(in: canvas, edgeMargin: options.gap)
    }

    private func rememberWidths() {
        for session in coordinator.sessions.values {
            for column in session.state.layout.columns {
                for slot in column.slots { for member in slot.members { preferredWidth[member] = column.width } }
            }
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
            expected.removeValue(forKey: wid); preferredWidth.removeValue(forKey: wid)
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
        let forced = forceApply || ProcessInfo.processInfo.systemUptime < forceUntil
        // Unchanged layout: skip writes (step 7b clears this for moved windows).
        if !forced, applied[space] == placements { return }
        let bounds = displayBounds()
        let display = coordinator.display(forSpace: space)
        let own = display.flatMap { bounds[$0.displayUUID] } ?? CGDisplayBounds(CGMainDisplayID())
        let others = bounds.filter { $0.key != display?.displayUUID }.map(\.value)
        var allConfirmed = true
        var unresponsive: Set<pid_t> = []
        for placement in placements {
            let wid = placement.windowID
            guard let element = references[wid] else { allConfirmed = false; continue }
            let row = byID[wid]
            if let row {
                guard row.spaceID == space else { allConfirmed = false; continue }
                // Do not fight a window that is temporarily not movable (open sheet).
                guard row.classification.eligibility == .tiled else { allConfirmed = false; continue }
            } else {
                // Its app was not surveyed (slow AX, e.g. busy right after
                // activation): still place it through the cached reference so
                // the strip does not show a gap, unless it is on another Space
                // or its app already failed a write this pass. Unconfirmed, so
                // it is verified again once the app answers.
                allConfirmed = false
                guard let pid = pidForWindow[wid], !unresponsive.contains(pid), Self.windowSpace(wid) == space else { continue }
            }
            let target = LiveReconciliation.park(placement.frame, canvas: session.canvas, display: own, otherDisplays: others)
            if let frame = row?.frame, matches(frame, target) {
                expected[wid] = (target, ProcessInfo.processInfo.systemUptime); displaced.removeValue(forKey: wid); continue
            }
            session.expect(windowID: wid, frame: target, now: ProcessInfo.processInfo.systemUptime, ticket: session.ticket)
            expected[wid] = (target, ProcessInfo.processInfo.systemUptime)
            log("write \(wid) on Space \(space): \(Int(target.x)),\(Int(target.y)) \(Int(target.width))x\(Int(target.height))")
            if !write(target, to: element) {
                allConfirmed = false
                if row == nil, let pid = pidForWindow[wid] { unresponsive.insert(pid) }
                log("write failed for \(wid)\(row == nil ? " (unsurveyed)" : "")")
            } else if row == nil {
                log("placed unsurveyed \(wid) via cached reference")
            }
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
        let t = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[paperi \(t)] \(message)\n".utf8))
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
        if let problem = LiveCommand.validate(args) { return ["ok": false, "error": problem] }
        switch args.first {
        case "pause": return pause()
        case "resume": return resume()
        case "stop": return ["ok": true, "stop": true]
        case "status" where paused: return ["ok": true, "paused": true]
        default: break
        }
        guard running else { return ["ok": false, "error": paused ? "paused (paperi msg resume)" : "not running"] }
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
            if changed { apply(space: ctx.space, byID: surveyByID()); rememberWidths() }
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
        return ["ok": true, "paused": false, "apps": options.config.include?.sorted() ?? ["all regular apps"], "displays": displays, "sessions": sessions,
                "floating": userFloating.sorted(), "journaled": journal.count, "lastRefreshMS": lastRefreshMS]
    }
}
