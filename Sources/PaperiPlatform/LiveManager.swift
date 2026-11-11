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
    /// Neighbour chosen when the focused window closed (`focusAfterClose`). It
    /// overrides the OS focus briefly, while its raise and app activation land.
    private var closeFocus: (window: UInt32, until: Double)?
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
        destroyedNotified.removeAll(); closeFocus = nil; slowUntil.removeAll(); forceApply = true
        coordinator = DisplaySpaceCoordinator(ownerPIDs: [], displays: topologies())
        recorder = EventRecorder(workspaceCenter: NSWorkspace.shared.notificationCenter,
                                 runningApplications: { NSWorkspace.shared.runningApplications },
                                 filter: { [config = options.config] app in Self.considered(app, config: config) },
                                 observeWorkspaceEvents: true,
                                 emit: { [weak self] event in self?.receive(event) })
        recorder.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelMotion(); self?.motionFrames.removeAll() }
        })
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
            MainActor.assumeIsolated { self?.cancelMotion(); self?.motionFrames.removeAll(); self?.forceApply = true; self?.scheduleRefresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkGestureSettings()
                self?.refresh()
            }
        }
        updateTouchSource()
        refresh()
    }

    /// Starts in the paused state without touching any window (e.g. the
    /// display arrangement is unsupported); `resume` starts management.
    public func startPaused() throws {
        guard !running, !paused else { return }
        guard AXIsProcessTrusted() else { throw LiveError.accessibility }
        try restoreStaleJournal()
        paused = true
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
        if let problem = DisplayArrangement.currentProblem() {
            return ["ok": false, "paused": paused, "error": problem]
        }
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
        updateTouchSource()
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
        cancelMotion(); motionFrames.removeAll()
        touchSource?.stop(); touchSource = nil
        slotSwipe?.cancel(); slotSwipe = nil
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
            // The window a swipe-up is closing: its release finishes the overlay.
            if let state = swipe, state.closing, state.released == true, state.closeWindow == wid {
                destroyedNotified.insert(wid)
                return
            }
            cancelMotion(); motionFrames.removeAll()
            destroyedNotified.insert(wid)
        }
        let ownMinimize = name == kAXWindowMiniaturizedNotification && swipe.map {
            $0.pulling && $0.pullAction == .minimize && $0.released == true && $0.closeWindow == event["windowID"] as? UInt32
        } == true
        // ⌘N from a released new-window swipe opens a window under the overlay.
        let ownNewWindow = name == kAXWindowCreatedNotification && swipe.map { $0.showsNewWindow && $0.released == true } == true
        if motionActive && !ownMinimize && !ownNewWindow && [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                                            kAXWindowCreatedNotification].contains(name) {
            cancelMotion(); motionFrames.removeAll()
        }
        if name == kAXResizedNotification, let state = swipe, state.released == nil {
            cancelMotion(); motionFrames.removeAll()
        }
        if name == kAXMovedNotification || name == kAXResizedNotification {
            // Our own writes echo back; refresh decides whether it was external.
        }
        if ["recorderReady", "recorderReconciled", "windowDiscovery", "subscriptionRetry"].contains(name) { return }
        scheduleRefresh()
    }

    private func activeSpaceChanged() {
        cancelMotion(); motionFrames.removeAll()
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
                    self.refresh()
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
        if motionActive { return }
        motionFrames.removeAll()
        if animateCachedFocus() { return }
        // Side-by-side displays are unsupported (the app pauses moments later);
        // no pass may run in between and push a window onto the other display.
        guard DisplayArrangement.currentProblem() == nil else { return }
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
        // Spaces whose strip lost a window: the survivors close the gap animated.
        var closedSpaces = Set(gone.compactMap { coordinator.spaceForWindow[$0] })
        var closeTarget = neighbourAfterClose(gone)
        if !gone.isEmpty { removeMembers(gone) }
        if let closeTarget {
            closeFocus = (closeTarget, ProcessInfo.processInfo.systemUptime + 0.8)
            log("focus after close: \(closeTarget)")
        }
        preferredWidth = preferredWidth.filter { levels[$0.key] != nil }

        let discoveryStart = ProcessInfo.processInfo.systemUptime
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

        phaseMS["discovery"] = (ProcessInfo.processInfo.systemUptime - discoveryStart) * 1000
        latestSurvey = byID
        let topologyStart = ProcessInfo.processInfo.systemUptime

        // 3. Definitive state changes (minimized, fullscreen, floated by the
        // user or a rule) leave the strip. Transient metadata, e.g. a sheet
        // making its parent temporarily non-movable, keeps the slot.
        // A minimized window leaves like a closed one: the survivors close the
        // gap animated, and focus follows `focusAfterClose`.
        let minimized = Set(byID.filter { coordinator.spaceForWindow[$0.key] != nil && $0.value.facts.minimized == true
            && isActiveRepresentative($0.key) }.keys)
        if !minimized.isEmpty {
            let members = Set(minimized.flatMap { coordinator.session(containing: $0)?.members(of: $0) ?? [$0] })
            closedSpaces.formUnion(minimized.compactMap { coordinator.spaceForWindow[$0] })
            if closeTarget == nil, let target = neighbourAfterClose(members) {
                closeTarget = target
                closeFocus = (target, ProcessInfo.processInfo.systemUptime + 0.8)
                log("focus after minimize: \(target)")
            }
        }
        for (wid, row) in byID where coordinator.spaceForWindow[wid] != nil &&
            (row.facts.minimized == true || row.facts.fullscreen == true || row.floatRequested) {
            if isActiveRepresentative(wid) { _ = try? coordinator.removeContainer(containing: wid, classification: Self.tiled) }
        }

        // 4. Representatives that changed Space (Mission Control drag, display drag).
        for (wid, row) in byID {
            guard let current = coordinator.spaceForWindow[wid], let space = row.spaceID, space != current,
                  isActiveRepresentative(wid), coordinator.sessions[space] != nil else { continue }
            let fromDisplay = coordinator.display(forSpace: current)?.displayUUID
            if (try? coordinator.transferContainer(containing: wid, to: space, classification: Self.tiled)) != nil {
                forceApply = true
                log("container of \(wid) followed to Space \(space)")
                // Restoring the pre-Paperi frame would pull the window back to
                // its old display: remember where it landed instead.
                if let display = coordinator.display(forSpace: space), display.displayUUID != fromDisplay,
                   let frame = row.frame, let members = coordinator.session(containing: wid)?.members(of: wid) {
                    let landed = LiveReconciliation.fit(frame, into: display.canvas)
                    for member in members { if let entry = journal[member] { journal[member] = (entry.pid, landed) } }
                    persistJournal()
                }
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

        phaseMS["topology"] = (ProcessInfo.processInfo.systemUptime - topologyStart) * 1000
        let layoutStart = ProcessInfo.processInfo.systemUptime
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
            focusedWindow = Self.frontToBack().first { id in
                self.pidForWindow[id] == pid && self.coordinator.spaceForWindow[id].map(activeSpaces.contains) == true
                    && self.isActiveRepresentative(id)
            }
            raiseAfterApply = focusedWindow
        }
        var focusedPID = front?.processIdentifier
        if let hold = closeFocus {
            // A click (or the target being reached, gone, or overdue) ends the hold.
            if mouseDown || focusedWindow == hold.window || ProcessInfo.processInfo.systemUptime > hold.until
                || !isActiveRepresentative(hold.window) || pidForWindow[hold.window] == nil {
                closeFocus = nil
            } else {
                focusedWindow = hold.window; focusedPID = pidForWindow[hold.window]
                raiseAfterApply = nil
            }
        }
        var focusAnimationSpace: UInt64?
        for (space, session) in coordinator.sessions where activeSpaces.contains(space) {
            let previousOffset = session.state.layout.offset
            let owned = focusedWindow.flatMap { session.slots[$0] != nil ? $0 : nil }
            let classification = owned != nil ? Self.tiled : WindowPolicy.classify(WindowFacts(bundleID: "foreign"))
            try? session.focus(windowID: owned, ownerPID: owned != nil ? focusedPID : nil,
                               classification: classification, ticket: session.ticket)
            // Removals, insertions and focus changes can leave the focused
            // column partly off-canvas; reveal is minimal and idempotent.
            if !mouseDown { reveal(session) }
            // A click can update focus while the mouse is down; reveal is
            // deferred until release, when the stored focus already matches.
            // The reveal's offset change is the animation trigger.
            if owned != nil, previousOffset != session.state.layout.offset,
               !forceApply, ProcessInfo.processInfo.systemUptime >= forceUntil {
                focusAnimationSpace = space
            }
        }
        if focusAnimationSpace == nil, !forceApply, ProcessInfo.processInfo.systemUptime >= forceUntil {
            focusAnimationSpace = closedSpaces.first { activeSpaces.contains($0) && coordinator.sessions[$0] != nil }
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

        phaseMS["layout"] = (ProcessInfo.processInfo.systemUptime - layoutStart) * 1000
        // 8. Effects, deferred to mouse up (no AX event may follow the release).
        if mouseDown {
            refreshOnMouseUp()
        } else {
            for space in activeSpaces where space != focusAnimationSpace { apply(space: space, byID: byID) }
            if let space = focusAnimationSpace {
                commandStarted = ProcessInfo.processInfo.systemUptime
                firstWriteMS = nil; finalWriteMS = nil; confirmedMS = nil
                animateFocus(space: space, byID: byID)
            }
            forceApply = false
            if let wid = raiseAfterApply, let element = references[wid] {
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                log("raised \(wid): app activated without a focused window")
            }
            if let wid = closeTarget, closeFocus?.window == wid, raise(wid) { log("raised \(wid) after close") }
        }
        rememberWidths()
        lastRefreshMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    }

    /// When the window Paperi last saw focused closes and takes its whole
    /// column with it, the representative to focus instead: the nearest
    /// surviving column on the configured side, else the other side. A
    /// surviving tab or stacked window keeps the column, so macOS's choice
    /// stands. Chosen before removal, while the closed column's index exists.
    private func neighbourAfterClose(_ gone: Set<UInt32>) -> UInt32? {
        let preference = options.config.focusAfterClose
        guard preference != .system else { return nil }
        for session in coordinator.sessions.values {
            guard let focused = session.state.osFocusedWindow, gone.contains(focused),
                  let slotID = session.slots[focused], let loc = session.state.layout.index(of: slotID) else { continue }
            let columns = session.state.layout.columns
            func survivor(_ column: Int) -> UInt32? {
                columns[column].slots.lazy.map(\.activeMember).first { !gone.contains($0) }
            }
            if columns[loc.column].slots.contains(where: { $0.members.contains { !gone.contains($0) } }) { return nil }
            let left = stride(from: loc.column - 1, through: 0, by: -1).lazy.compactMap(survivor).first
            let right = (loc.column + 1 ..< columns.count).lazy.compactMap(survivor).first
            return preference == .left ? left ?? right : right ?? left
        }
        return nil
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

    private var phaseMS: [String: Double] = [:]
    private var axWriteCalls = 0
    private var axWriteMS = 0.0
    private var latestSurvey: [UInt32: Survey] = [:]
    private var motionBegan: Double?
    private var motionFailed: Set<UInt32> = []
    private var motionBlocked: Set<UInt32> = []
    private var motionTicks = 0
    private var motionSpace: UInt64?
    private var motionTimer: Timer?
    private var motionBounce: Direction?
    private var motionGeneration: UInt64 = 0
    private var motionFrames: [UInt32: Rect] = [:]
    private var commandStarted = 0.0
    private var firstWriteMS: Double?
    private var finalWriteMS: Double?
    private var confirmedMS: Double?
    private var tickMS = 0.0
    private var missedTicks = 0

    private func cancelMotion() {
        cancelSwipe()
        motionGeneration &+= 1
        motionTimer?.invalidate(); motionTimer = nil
        motionBounce = nil
    }

    /// Reveal an existing representative before the expensive all-app survey.
    /// WindowServer supplies current frames; unknown windows still take the full
    /// reconciliation path. A normal refresh follows animation completion.
    private func animateCachedFocus() -> Bool {
        // A pending close must go through the full pass so the gap is removed.
        guard !forceApply, ProcessInfo.processInfo.systemUptime >= forceUntil, destroyedNotified.isEmpty, closeFocus == nil,
              NSEvent.pressedMouseButtons == 0, drag == nil,
              (options.config.focusScrollDuration ?? 0.22) > 0,
              DisplayArrangement.currentProblem() == nil,
              let front = NSWorkspace.shared.frontmostApplication else { return false }
        let application = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.02)
        guard let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let wid = paperi_window_id((value as! AXUIElement))
        guard pidForWindow[wid] == front.processIdentifier, isActiveRepresentative(wid),
              let space = coordinator.spaceForWindow[wid],
              Self.windowSpace(wid) == space,
              coordinator.display(forSpace: space)?.activeSpaceID == space,
              let session = coordinator.sessions[space], !session.state.interactionSuppressed,
              let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap),
              let surveys = cachedStripSurveys(space: space, placements: placements) else { return false }
        let offset = session.state.layout.offset
        try? session.focus(windowID: wid, ownerPID: front.processIdentifier,
                           classification: Self.tiled, ticket: session.ticket)
        reveal(session)
        guard session.state.layout.offset != offset else { return false }
        commandStarted = ProcessInfo.processInfo.systemUptime
        firstWriteMS = nil; finalWriteMS = nil; confirmedMS = nil
        animateFocus(space: space, byID: surveys)
        return true
    }

    /// Cached surveys for every window placed on `space`, carrying current
    /// WindowServer frames; nil when any of them is unknown, not tiled, or
    /// not on that Space (the caller then takes the full refresh path).
    private func cachedStripSurveys(space: UInt64, placements: [Placement]) -> [UInt32: Survey]? {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var frames: [UInt32: Rect] = [:]
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            frames[id] = Rect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        }
        var surveys: [UInt32: Survey] = [:]
        for placement in placements {
            let id = placement.windowID
            guard let cached = latestSurvey[id], cached.spaceID == space,
                  cached.classification.eligibility == .tiled,
                  let frame = frames[id], Self.windowSpace(id) == space else { return nil }
            surveys[id] = Survey(windowID: id, pid: cached.pid, element: cached.element,
                                 classification: cached.classification, facts: cached.facts,
                                 floatRequested: cached.floatRequested, spaceID: space, frame: frame)
        }
        return surveys
    }

    /// One target calculation, position-only ticks, no discovery in the scheduler.
    private func animateFocus(space: UInt64, byID: [UInt32: Survey], bounce: Direction? = nil) {
        // Key repeat must not stack excursions or keep restarting the return.
        if let bounce, motionTimer != nil, motionBounce == bounce, motionSpace == space { return }
        let configuredDuration = options.config.focusScrollDuration ?? 0.22
        let duration = bounce == nil || configuredDuration == 0 ? configuredDuration : max(0.28, configuredDuration)
        guard NSEvent.pressedMouseButtons == 0 else { cancelMotion(); refreshOnMouseUp(); return }
        guard duration > 0, let session = coordinator.sessions[space],
              let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else {
            apply(space: space, byID: byID)
            if let session = coordinator.sessions[space],
               let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) {
                let targets = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
                confirmFocus(targets: targets, generation: motionGeneration, attempts: 3)
            }
            return
        }
        let targets = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
        var starts: [UInt32: Rect] = [:]
        for placement in placements {
            let wid = placement.windowID
            guard let row = byID[wid], row.spaceID == space, row.classification.eligibility == .tiled,
                  let frame = motionFrames[wid] ?? row.frame, let target = targets[wid] else {
                cancelMotion(); apply(space: space, byID: byID); return
            }
            // Position-only animation cannot apply admission or resize changes.
            guard abs(frame.width - target.width) <= 2, abs(frame.height - target.height) <= 2 else {
                cancelMotion(); apply(space: space, byID: byID); return
            }
            if bounce != nil || !matches(frame, target) { starts[wid] = frame }
        }
        cancelMotion()
        guard !starts.isEmpty else { return }
        let generation = motionGeneration
        motionBegan = nil; motionFailed.removeAll(); motionBlocked.removeAll(); motionTicks = 0
        let origins = starts
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.motionGeneration == generation else { return }
                guard self.running, NSEvent.pressedMouseButtons == 0, AXIsProcessTrusted(),
                      self.coordinator.display(forSpace: space)?.activeSpaceID == space else {
                    self.cancelMotion(); self.motionFrames.removeAll(); self.scheduleRefresh(); return
                }
                let tick = ProcessInfo.processInfo.systemUptime
                if self.motionBegan == nil { self.motionBegan = tick }
                let progress = min(1, (tick - (self.motionBegan ?? tick)) / duration)
                let eased = progress * progress * (3 - 2 * progress)
                self.motionTicks += 1
                for (wid, origin) in origins where !self.motionBlocked.contains(wid) {
                    guard NSEvent.pressedMouseButtons == 0 else {
                        self.cancelMotion(); self.motionFrames.removeAll(); self.refreshOnMouseUp(); return
                    }
                    guard let target = targets[wid], let element = self.references[wid] else { continue }
                    var frame = origin
                    frame.x = origin.x + (target.x - origin.x) * eased
                    frame.y = origin.y + (target.y - origin.y) * eased
                    if let bounce {
                        frame = LiveReconciliation.edgeBounce(frame, toward: bounce, progress: progress)
                    }
                    if let last = self.motionFrames[wid], last == frame { continue }
                    var point = CGPoint(x: frame.x, y: frame.y)
                    guard let value = AXValueCreate(.cgPoint, &point) else { continue }
                    session.expect(windowID: wid, frame: frame, now: tick, ticket: session.ticket)
                    self.expected[wid] = (frame, tick)
                    let writeStart = ProcessInfo.processInfo.systemUptime
                    AXUIElementSetMessagingTimeout(element, 0.02)
                    let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
                    AXUIElementSetMessagingTimeout(element, 0.2)
                    self.axWriteCalls += 1
                    self.axWriteMS += (ProcessInfo.processInfo.systemUptime - writeStart) * 1000
                    if self.firstWriteMS == nil { self.firstWriteMS = (writeStart - self.commandStarted) * 1000 }
                    if result != .success {
                        self.motionFailed.insert(wid)
                        // A busy app can time out during activation. Retry at
                        // the next tick's current position instead of leaving
                        // it stationary for the rest of the animation. Each
                        // attempt remains bounded by the 20 ms timeout.
                        if result != .cannotComplete { self.motionBlocked.insert(wid) }
                        continue
                    }
                    self.motionFailed.remove(wid)
                    self.motionFrames[wid] = frame
                }
                self.tickMS = (ProcessInfo.processInfo.systemUptime - tick) * 1000
                if self.tickMS > 1000 / 60 { self.missedTicks += 1 }
                if progress >= 1 {
                    self.finalWriteMS = (ProcessInfo.processInfo.systemUptime - self.commandStarted) * 1000
                    self.cancelMotion(); self.motionFrames.removeAll()
                    self.applied.removeValue(forKey: space)
                    self.confirmFocus(targets: targets, generation: self.motionGeneration, attempts: 3)
                    self.scheduleRefresh()
                }
            }
        }
        motionSpace = space
        motionBounce = bounce
        motionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Bounded observation, reported separately from the time of the final write.
    private func confirmFocus(targets: [UInt32: Rect], generation: UInt64, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.motionGeneration == generation,
                      NSEvent.pressedMouseButtons == 0 else { return }
                let confirmed = targets.allSatisfy { wid, target in
                    guard let element = self.references[wid], let frame = Diagnostics.frame(element) else { return false }
                    return self.matches(frame, target)
                }
                if confirmed {
                    self.confirmedMS = (ProcessInfo.processInfo.systemUptime - self.commandStarted) * 1000
                } else if attempts > 1 {
                    self.confirmFocus(targets: targets, generation: generation, attempts: attempts - 1)
                }
            }
        }
    }

    // MARK: swipe (snapshot renderer)

    /// One swipe: the strip's images follow `progress` towards at most one
    /// neighbour (−1 = left neighbour fully revealed, 1 = right). Nothing real
    /// moves and nothing logical changes until a committed release.
    private struct Swipe {
        let space: UInt64
        let generation: UInt64
        let overlay: SnapshotTransition
        let surveys: [UInt32: Survey]
        let ends: [Direction: [UInt32: Rect]]
        let neighbours: [Direction: UInt32]
        let canvas: Rect
        /// The focused window a swipe up would close, if it is on screen.
        let closeWindow: UInt32?
        /// The fingers locked vertically: images track a close (up) or a
        /// pull (down, `pulling`: minimize or new window), not the strip.
        var closing = false
        var pulling = false
        var pullAction: LiveConfig.SwipeDownAction = .minimize
        /// The close-tab indicator replaces moving the window.
        var showsTabClose: Bool { closing && !pulling && tabClose != nil }
        /// The new-window indicator replaces moving the window.
        var showsNewWindow: Bool { closing && pulling && pullAction == .newWindow }
        var showsIndicator: Bool { showsTabClose || showsNewWindow }
        var indicatorStyle: GestureIndicatorStyle { showsNewWindow ? .newWindow : .closeTab }
        /// Set when a swipe up closes a tab rather than the window: the window
        /// stays put and a close-tab indicator tracks the fingers instead.
        let tabClose: TabClose?
        var starts: [UInt32: Rect] = [:]
        var progress = 0.0
        var targetProgress = 0.0
        var lastVisualTime = 0.0
        /// On-screen speed of the images, progress per second (smoothed).
        var visualVelocity = 0.0
        /// Tracking frame pacing, as the display clock delivered it.
        var lastFrameTime = 0.0
        var frames = 0
        var droppedFrames = 0
        var maxFrameMS = 0.0
        var ready = false
        var tracking = true
        var failed = false
        var released: Bool?
        var releaseDirection: Direction?
    }
    enum TabClose: String {
        /// The window is the front tab of a native tab group (AX press).
        case native
        /// The app is listed in `gesture.tabCloseApps`; its tabs close with ⌘W.
        case app
    }
    private var swipe: Swipe?
    private var swipeTask: Task<Void, Never>?
    private var swipeGuard: Timer?
    private var swipeSimulation: Timer?
    private var swipeMetrics: [String: Any] = [:]
    private var swipeBegan = 0.0
    private var touchSource: TouchSource?
    private var slotSwipe: SlotSwipe?
    private var lastGestureConflicts: [String]?
    /// Travel past the strip's ends, in points, at full progress.
    private static let swipeEdgeResistance = 40.0

    private var motionActive: Bool { motionTimer != nil || swipe != nil }
    /// A focus scroll or a released swipe's landing/snap-back is on screen.
    /// Gesture input is ignored until it finishes; live finger tracking is not
    /// an animation.
    private var gestureBlockedByAnimation: Bool { motionTimer != nil || swipe?.released != nil }

    private func cancelSwipe() {
        swipeGuard?.invalidate(); swipeGuard = nil
        swipeSimulation?.invalidate(); swipeSimulation = nil
        swipeTask?.cancel(); swipeTask = nil
        slotSwipe?.cancel(); slotSwipe = nil
        guard let state = swipe else { return }
        state.overlay.hide()
        swipe = nil
        swipeMetrics["state"] = "cancelled"
    }

    static let fullScreenRefusal = "pointer is over a full-screen Space"

    /// The display under the pointer, as SkyLight reports it.
    private func pointerDisplay() -> DisplaySpaceTopology? {
        let mouseLoc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }) else { return nil }
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let uuid = CGDisplayCreateUUIDFromDisplayID(screenID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "Main"
        return coordinator.displays.first(where: { $0.displayUUID == uuid })
    }

    /// The display under the pointer is showing a Space without a strip
    /// (full-screen apps and other non-desktop Spaces).
    private func pointerOverUnmanagedSpace() -> Bool {
        guard let display = pointerDisplay(), let space = display.activeSpaceID else { return false }
        return !display.userSpaces.contains(space)
    }

    private func pointerContext() -> (session: ScopedLayoutSession, space: UInt64, pid: pid_t, window: UInt32)? {
        guard let display = pointerDisplay(),
              let space = display.activeSpaceID,
              let session = coordinator.sessions[space],
              let focused = session.state.layout.focused,
              let loc = session.state.layout.index(of: focused) else { return nil }
        let wid = session.state.layout.columns[loc.column].slots[loc.row].activeMember
        guard let pid = pidForWindow[wid] else { return nil }
        return (session, space, pid, wid)
    }

    func updateTouchSource() {
        touchSource?.stop()
        touchSource = nil
        guard running, !paused, options.config.gesture.enabled else { return }
        let conflicts = GestureConflict.checkLive(fingers: options.config.gesture.fingers)
        guard conflicts.isEmpty else {
            if options.verbose { log("trackpad swipe disabled due to conflicts: \(conflicts.joined(separator: ", "))") }
            return
        }
        let source = EventTapTouchSource(fingers: options.config.gesture.fingers, verbose: options.verbose)
        source.onEvent = { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleTouchEvent(event)
            }
        }
        source.start()
        touchSource = source
    }

    func checkGestureSettings() {
        let conflicts = GestureConflict.checkLive(fingers: options.config.gesture.fingers)
        if conflicts != lastGestureConflicts {
            lastGestureConflicts = conflicts
            updateTouchSource()
        }
    }

    private func handleTouchEvent(_ event: TouchEvent) {
        guard running, !paused, DisplayArrangement.currentProblem() == nil else {
            cancelSwipe()
            slotSwipe?.cancel()
            slotSwipe = nil
            return
        }
        switch event {
        case .begin(let time):
            // Ignore the whole contact sequence if it starts during an
            // animation: interrupting a landing could capture the previous
            // overlay, and a focus scroll must not be cancelled by a touch.
            guard !gestureBlockedByAnimation else { return }
            // Capture while determining the axis, but keep the overlay hidden
            // until horizontal movement locks. This overlaps input with capture.
            let started = beginSwipe(pendingLock: true)
            // Nothing to swipe on a full-screen Space; a retry on horizontal
            // lock would refuse again (and refresh again).
            if started["error"] as? String == Self.fullScreenRefusal { return }
            let cfg = SlotSwipe.Configuration(
                travel: options.config.gesture.travel,
                commitThreshold: options.config.gesture.commitThreshold,
                flickVelocity: options.config.gesture.flickVelocity,
                invert: options.config.gesture.invert,
                closeTravel: options.config.gesture.swipeUpToClose ? options.config.gesture.travel : nil,
                pullTravel: options.config.gesture.swipeDown == .none ? nil : options.config.gesture.travel
            )
            var swipeReducer = SlotSwipe(config: cfg)
            swipeReducer.begin(at: time)
            slotSwipe = swipeReducer

        case .move(let dx, let dy, let time):
            guard var swipeReducer = slotSwipe else { return }
            if let action = swipeReducer.move(dx: dx, dy: dy, at: time) {
                switch action {
                case .started:
                    let res: [String: Any] = swipe != nil ? ["ok": true] : beginSwipe()
                    if res["ok"] as? Bool != true {
                        swipeReducer.cancel()
                        slotSwipe = nil
                        return
                    }
                    if case .active(_, let progress, _, _) = swipeReducer.state {
                        updateSwipe(progress)
                    }
                case .updated(let progress):
                    updateSwipe(progress)
                case .closeStarted:
                    let res: [String: Any] = swipe != nil ? ["ok": true] : beginSwipe()
                    guard res["ok"] as? Bool == true, startClosing() else {
                        cancelSwipe()
                        slotSwipe = nil
                        return
                    }
                    if case .closing(_, let progress, _, _) = swipeReducer.state {
                        updateSwipe(progress)
                    }
                case .closeUpdated(let progress), .pullUpdated(let progress):
                    updateSwipe(progress)
                case .pullStarted:
                    let res: [String: Any] = swipe != nil ? ["ok": true] : beginSwipe()
                    guard res["ok"] as? Bool == true, startClosing(pull: true) else {
                        cancelSwipe()
                        slotSwipe = nil
                        return
                    }
                    if case .pulling(_, let progress, _, _) = swipeReducer.state {
                        updateSwipe(progress)
                    }
                case .cancelled:
                    cancelSwipe()
                    slotSwipe = nil
                    return
                case .finished:
                    break
                }
            }
            slotSwipe = swipeReducer

        case .end(let time):
            guard var swipeReducer = slotSwipe else { return }
            let decision = swipeReducer.end(at: time)
            slotSwipe = nil
            switch decision {
            case .commit(let direction):
                endSwipe(commit: true, direction: direction)
            case .close, .pull:
                endSwipe(commit: true)
            case .snapBack:
                endSwipe(commit: false)
            }

        case .cancel:
            // Only a sequence we are tracking may cancel; an ignored one must
            // not tear down a running landing.
            guard slotSwipe != nil else { return }
            cancelSwipe()
            slotSwipe?.cancel()
            slotSwipe = nil
        }
    }

    /// Captures the strip of the focused window's Space and shows it frozen
    /// in place. Updates and a release may arrive before the capture finishes.
    @discardableResult func beginSwipe(isSimulation: Bool = false, pendingLock: Bool = false) -> [String: Any] {
        func fail(_ reason: String) -> [String: Any] {
            swipeMetrics = ["state": "refused", "reason": reason]
            return ["ok": false, "error": reason]
        }
        guard !gestureBlockedByAnimation else { return ["ok": false, "error": "animation in progress"] }
        cancelMotion(); motionFrames.removeAll()
        guard running, AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0, drag == nil else { return fail("mouse interaction") }
        guard DisplayArrangement.currentProblem() == nil else { return fail("display arrangement") }
        if !isSimulation {
            guard options.config.gesture.enabled else { return fail("gesture disabled") }
            let conflicts = GestureConflict.checkLive(fingers: options.config.gesture.fingers)
            guard conflicts.isEmpty else { return fail("blocked by system gestures: \(conflicts.joined(separator: ", "))") }
        }
        // The swipe belongs to the display under the pointer. If that display
        // shows a full-screen Space there is no strip, and falling back to the
        // focused window could scroll another display's strip.
        guard !pointerOverUnmanagedSpace() else { return fail(Self.fullScreenRefusal) }
        let ctx: (session: ScopedLayoutSession, space: UInt64, pid: pid_t, window: UInt32)
        if let pointer = pointerContext() {
            ctx = pointer
        } else {
            // focusedContext refreshes first, so the Spaces may have changed
            // (e.g. the app under the pointer has just entered full screen).
            guard let focused = focusedContext() else { return fail("no managed window focused") }
            guard !pointerOverUnmanagedSpace() else { return fail(Self.fullScreenRefusal) }
            ctx = focused
        }
        let session = ctx.session, space = ctx.space
        guard coordinator.display(forSpace: space)?.activeSpaceID == space, !session.state.interactionSuppressed,
              let current = try? session.state.layout.placements(in: session.canvas, gap: options.gap),
              let surveys = cachedStripSurveys(space: space, placements: current) else {
            scheduleRefresh(); return fail("strip not settled")
        }
        var ends: [Direction: [UInt32: Rect]] = [:], neighbours: [Direction: UInt32] = [:]
        for direction in [Direction.left, .right] {
            // A swipe moves the strip: target the nearest column in that
            // direction that needs scrolling to reveal. If every column that
            // way is already fully visible, fall back to the adjacent one.
            var layout = session.state.layout
            var candidate = layout
            var firstStep: Layout?
            var scrolled = false
            while let id = candidate.neighbor(direction) {
                candidate.focused = id
                if firstStep == nil { firstStep = candidate }
                if (try? candidate.reveal(in: session.canvas, gap: options.gap)) == true { scrolled = true; break }
            }
            guard let chosen = scrolled ? candidate : firstStep else { continue }
            layout = chosen
            _ = try? layout.reveal(in: session.canvas, gap: options.gap)
            guard let id = layout.focused, let loc = layout.index(of: id) else { continue }
            guard let placements = try? layout.placements(in: session.canvas, gap: options.gap) else { continue }
            let targets = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
            // Images keep their size; a size change cannot be shown by sliding.
            guard surveys.allSatisfy({ wid, row in
                guard let frame = row.frame, let target = targets[wid] else { return false }
                return abs(frame.width - target.width) <= 2 && abs(frame.height - target.height) <= 2
            }) else { scheduleRefresh(); return fail("strip not settled") }
            ends[direction] = targets
            neighbours[direction] = layout.columns[loc.column].slots[loc.row].activeMember
        }
        let generation = motionGeneration
        let overlay = SnapshotTransition()
        // Only the focused tiled window closes, and only if its image is captured.
        let closeWindow = session.state.layout.focused == nil || surveys[ctx.window] == nil ? nil : ctx.window
        let tabClose: TabClose? = closeWindow.flatMap { wid in
            let bundleID = NSRunningApplication(processIdentifier: ctx.pid)?.bundleIdentifier
            if let bundleID, options.config.gesture.tabCloseApps.contains(bundleID) { return .app }
            return tabGroup(wid).count > 1 ? .native : nil
        }
        swipe = Swipe(space: space, generation: generation, overlay: overlay, surveys: surveys,
                      ends: ends, neighbours: neighbours, canvas: session.canvas, closeWindow: closeWindow,
                      tabClose: tabClose, tracking: !pendingLock)
        motionSpace = space
        swipeBegan = ProcessInfo.processInfo.systemUptime
        swipeMetrics = ["state": "capturing", "windows": surveys.count]
        let guardTimer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.swipe != nil else {
                    self.swipeGuard?.invalidate(); self.swipeGuard = nil; return
                }
                if NSEvent.pressedMouseButtons != 0 || !AXIsProcessTrusted()
                    || self.coordinator.display(forSpace: space)?.activeSpaceID != space
                    || DisplayArrangement.currentProblem() != nil {
                    self.cancelMotion(); self.scheduleRefresh()
                }
            }
        }
        swipeGuard = guardTimer
        RunLoop.main.add(guardTimer, forMode: .common)
        let canvas = session.canvas
        swipeTask = Task { [weak self] in
            do {
                try await overlay.prepare(windows: Set(surveys.keys), canvas: canvas)
                guard let self, var state = self.swipe, state.generation == generation else { overlay.hide(); return }
                guard self.running, AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0,
                      self.coordinator.display(forSpace: space)?.activeSpaceID == space else {
                    self.cancelMotion(); self.scheduleRefresh(); return
                }
                state.starts = overlay.captured
                state.ready = true
                self.swipe = state
                self.swipeMetrics = ["state": "tracking", "windows": surveys.count, "captureMS": overlay.captureMS,
                                     "textureBytes": overlay.textureBytes]
                // A quick gesture can finish before capture. Begin that release
                // at the real windows instead of flashing a displaced snapshot.
                overlay.place(state.starts)
                state.lastVisualTime = CACurrentMediaTime()
                self.swipe = state
                if state.tracking { overlay.show() }
                overlay.startFrameClock { [weak self] link in self?.advanceSwipeVisuals(link) }
                if let commit = state.released { state.released = nil; self.swipe = state; self.endSwipe(commit: commit, direction: state.releaseDirection) }
            } catch {
                overlay.hide()
                guard let self, var state = self.swipe, state.generation == generation else { return }
                state.failed = true
                self.swipe = state
                self.swipeMetrics = ["state": "fallback", "reason": String(describing: error)]
                if let commit = state.released { state.released = nil; self.swipe = state; self.endSwipe(commit: commit, direction: state.releaseDirection) }
            }
        }
        return ["ok": true, "neighbours": neighbours.count]
    }

    /// Switches a tracking swipe to closing its focused window, or to a pull
    /// (down: minimize it or open a new window, per `gesture.swipeDown`).
    private func startClosing(pull: Bool = false) -> Bool {
        guard var state = swipe, state.released == nil, state.closeWindow != nil else { return false }
        if pull, options.config.gesture.swipeDown == .none { return false }
        state.closing = true
        state.pulling = pull
        state.pullAction = options.config.gesture.swipeDown
        swipe = state
        // Nothing moves: show only the indicator over the live windows.
        if state.showsIndicator { state.overlay.showIndicatorOnly() }
        return true
    }

    /// Keep only the newest finger target; the visual clock limits travel speed.
    func updateSwipe(_ progress: Double) {
        guard var state = swipe, state.released == nil, progress.isFinite else { return }
        let wasTracking = state.tracking
        state.tracking = true
        state.targetProgress = state.closing ? min(1.3, max(0, progress)) : min(1.3, max(-1.3, progress))
        // Time the first tracked frame from now, not from when the capture
        // finished, so it takes a normal step rather than a catch-up one.
        if !wasTracking { state.lastVisualTime = CACurrentMediaTime() }
        swipe = state
        if state.ready && !wasTracking { state.overlay.show() }
    }

    /// One display frame: move the images to where they will be when it is shown.
    private func advanceSwipeVisuals(_ link: CADisplayLink) {
        guard var state = swipe, state.ready, state.tracking, state.released == nil else { return }
        let period = link.targetTimestamp - link.timestamp
        if state.lastFrameTime > 0, period > 0 {
            let interval = link.timestamp - state.lastFrameTime
            state.frames += 1
            state.maxFrameMS = max(state.maxFrameMS, interval * 1000)
            state.droppedFrames += max(0, Int((interval / period).rounded()) - 1)
        }
        state.lastFrameTime = link.timestamp
        let now = link.targetTimestamp
        let elapsed = now - state.lastVisualTime
        let next = SlotSwipe.followVisualProgress(state.progress, toward: state.targetProgress, elapsed: elapsed)
        if elapsed > 0 {
            let instant = (next - state.progress) / elapsed
            state.visualVelocity += (1 - exp(-elapsed / 0.03)) * (instant - state.visualVelocity)
        }
        state.lastVisualTime = now
        let changed = next != state.progress
        state.progress = next
        swipe = state
        guard changed else { return }
        if state.showsIndicator, let wid = state.closeWindow {
            state.overlay.trackIndicator(state.indicatorStyle, window: wid, progress: next,
                                         threshold: options.config.gesture.commitThreshold)
        } else {
            state.overlay.place(swipeFrames(state))
            if state.closing, let wid = state.closeWindow { state.overlay.setOpacity(wid, closeOpacity(next)) }
        }
    }

    private func swipeFrames(_ state: Swipe) -> [UInt32: Rect] { swipeFrames(state, progress: state.progress) }

    private func swipeFrames(_ state: Swipe, progress: Double) -> [UInt32: Rect] {
        // Closing a tab leaves the window where it is.
        if state.closing { return state.showsIndicator ? state.starts : closeFrames(state, progress: progress) }
        let direction: Direction = progress < 0 ? .left : .right
        guard let ends = state.ends[direction] else {
            // Strip end: resist, moving at most a few points.
            let shift = -Self.swipeEdgeResistance * progress
            return state.starts.mapValues { var frame = $0; frame.x += shift; return frame }
        }
        let absP = abs(progress)
        if absP <= 1.0 {
            return LiveReconciliation.interpolate(state.starts, ends, progress: absP, canvas: state.canvas)
        } else {
            let base = LiveReconciliation.interpolate(state.starts, ends, progress: 1.0, canvas: state.canvas)
            let extraShift = (direction == .left ? 1.0 : -1.0) * (absP - 1.0) * Self.swipeEdgeResistance
            return base.mapValues { var frame = $0; frame.x += extraShift; return frame }
        }
    }

    /// Swipe up (down): only the window being closed (minimized) moves,
    /// straight up (down). At 1 it and its shadow are just past that edge of
    /// its display; going down, it passes under the Dock.
    private func closeFrames(_ state: Swipe, progress: Double) -> [UInt32: Rect] {
        guard let wid = state.closeWindow, var frame = state.starts[wid] else { return state.starts }
        let distance = state.pulling
            ? state.overlay.screenBottom - frame.y + Self.closeShadowClearance
            : frame.y + frame.height - state.overlay.screenTop + Self.closeShadowClearance
        let absP = min(1, progress)
        frame.y -= (state.pulling ? -1 : 1) * (distance * absP + max(0, progress - 1) * Self.swipeEdgeResistance)
        var frames = state.starts
        frames[wid] = frame
        return frames
    }

    /// A closing window stays opaque until release would close it (the
    /// commit threshold), then fades slightly as it rises: 70% once fully off.
    private func closeOpacity(_ progress: Double) -> Double {
        let threshold = min(0.99, options.config.gesture.commitThreshold)
        return 1 - 0.3 * min(1, max(0, (progress - threshold) / (1 - threshold)))
    }

    /// Room for the active window shadow (radius 16, offset 8) above the display.
    private static let closeShadowClearance = 32.0

    enum CloseMethod: String { case press, key, none }

    /// Every native tab in the window's slot, itself included.
    private func tabGroup(_ wid: UInt32) -> Set<UInt32> {
        guard let space = coordinator.spaceForWindow[wid], let session = coordinator.sessions[space],
              let slot = session.state.layout.columns.lazy.flatMap(\.slots).first(where: { $0.members.contains(wid) })
        else { return [wid] }
        return Set(slot.members)
    }

    /// Presses the window's close button through Accessibility; in a native
    /// tab group that closes only the front tab. Without a usable close
    /// button (custom window controls), ⌘W goes to the app, but only while
    /// this window is its focused window, so it cannot close a different one.
    private func pressClose(_ wid: UInt32) -> CloseMethod {
        guard let pid = pidForWindow[wid], let element = references[wid] ?? findWindow(wid, pid: pid) else { return .none }
        // AppKit reports a disabled close button for windows without one, and
        // pressing it reports success while doing nothing.
        if let value = Diagnostics.attribute(element, kAXCloseButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID(),
           Diagnostics.attribute(value as! AXUIElement, kAXEnabledAttribute) as? Bool != false {
            if AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString) == .success { return .press }
        }
        return Self.sendCommandW(to: pid, window: wid) ? .key : .none
    }

    static let keyW: CGKeyCode = 13, keyN: CGKeyCode = 45

    private static func sendCommandW(to pid: pid_t, window wid: UInt32) -> Bool { sendCommand(keyW, to: pid, window: wid) }

    /// ⌘`key` to the app, only while `wid` is its focused window.
    private static func sendCommand(_ key: CGKeyCode, to pid: pid_t, window wid: UInt32) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        guard let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID(),
              paperi_window_id(value as! AXUIElement) == wid else { return false }
        // A private-state source is ignored as a key equivalent; HID state is not.
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return false }
            event.flags = .maskCommand
            event.postToPid(pid)
            if down { usleep(15_000) }
        }
        return true
    }

    /// Whether WindowServer still shows the window.
    private static func windowOnScreen(_ wid: UInt32) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
    }

    /// Committed swipe up: the image leaves through the top while the app
    /// closes the window underneath. The overlay goes once the window has
    /// gone, so the survivors' gap animation plays on the real windows. A
    /// window that stays (an unsaved-changes prompt) is revealed again.
    private func finishClose(_ state: Swipe, settle: Double) {
        guard let wid = state.closeWindow else { return }
        if state.showsNewWindow { finishNewWindow(state, window: wid); return }
        if state.pulling { finishMinimize(state, window: wid, settle: settle); return }
        if state.showsTabClose, let mode = state.tabClose { finishTabClose(state, window: wid, mode: mode); return }
        let generation = state.generation, overlay = state.overlay
        let from = state.progress, path = state
        // Leave at the speed the window had on screen, then slow to the edge.
        let distance = max(0, 1 - from)
        let duration = SlotSwipe.settleDuration(distance: distance, speed: state.visualVelocity, base: settle)
        let curve = SlotSwipe.settleCurve(speed: state.visualVelocity, distance: distance, duration: duration)
        overlay.slide(along: { u in self.closeFrames(path, progress: from + (1 - from) * u) },
                      to: closeFrames(path, progress: 1), duration: duration, curve: curve)
        overlay.fade(wid, to: closeOpacity(1), duration: duration, curve: curve)
        let released = ProcessInfo.processInfo.systemUptime
        let method = pressClose(wid)
        let pressed = method != .none
        swipeMetrics["closeMethod"] = method.rawValue
        swipeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 10))
            var gone = false
            if pressed {
                // Apps may finish their own work first; wait at most a second.
                for _ in 0..<40 {
                    guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
                    if self.destroyedNotified.contains(wid) || !Self.windowOnScreen(wid) { gone = true; break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
            if !gone {
                overlay.slide(to: path.starts, duration: 0.18)
                overlay.fade(wid, to: 1, duration: 0.18)
                try? await Task.sleep(for: .milliseconds(190))
            }
            guard self.swipe?.generation == generation, !Task.isCancelled else { return }
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil
            self.swipeMetrics["state"] = gone ? "closed" : (pressed ? "closeRefused" : "noCloseButton")
            self.swipeMetrics["closeMS"] = (ProcessInfo.processInfo.systemUptime - released) * 1000
            self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
            self.scheduleRefresh()
        }
    }

    /// Minimizes through Accessibility. False when the window refuses.
    private func minimize(_ wid: UInt32) -> Bool {
        guard let pid = pidForWindow[wid], let element = references[wid] ?? findWindow(wid, pid: pid) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXMinimizedAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Committed swipe down: the image leaves through the bottom (under the
    /// Dock) while macOS minimizes the window underneath. Its Genie/Scale
    /// effect plays below the overlay (measured: only the Dock changes on
    /// screen), and the window stays on screen until the effect ends (~0.55 s
    /// for Genie), so the overlay waits for that before fading.
    private func finishMinimize(_ state: Swipe, window wid: UInt32, settle: Double) {
        let generation = state.generation, overlay = state.overlay
        let from = state.progress, path = state
        let distance = max(0, 1 - from)
        let duration = SlotSwipe.settleDuration(distance: distance, speed: state.visualVelocity, base: settle)
        let curve = SlotSwipe.settleCurve(speed: state.visualVelocity, distance: distance, duration: duration)
        overlay.slide(along: { u in self.closeFrames(path, progress: from + (1 - from) * u) },
                      to: closeFrames(path, progress: 1), duration: duration, curve: curve)
        overlay.fade(wid, to: closeOpacity(1), duration: duration, curve: curve)
        let released = ProcessInfo.processInfo.systemUptime
        let done = minimize(wid)
        swipeMetrics["minimize"] = done
        swipeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 10))
            var gone = false
            if done {
                for _ in 0..<60 {
                    guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
                    if !Self.windowOnScreen(wid) { gone = true; break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
            var instantSpace: UInt64?
            if gone {
                // Close the gap inside the overlay, as a swipe lands: a refresh
                // after the fade would race it and could show a snap.
                let collapse = self.collapseGap(after: wid, state: path)
                self.swipeMetrics["gap"] = collapse.map { _ in "animated" } ?? "instant"
                if let collapse {
                    let duration = collapse.duration
                    try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
                    guard self.swipe?.generation == generation, !Task.isCancelled else { return }
                    await self.finishHandoff(overlay: overlay, targets: collapse.targets, generation: generation)
                    guard self.swipe?.generation == generation, !Task.isCancelled else { return }
                } else {
                    instantSpace = path.space
                }
            } else {
                overlay.slide(to: path.starts, duration: 0.18)
                overlay.fade(wid, to: 1, duration: 0.18)
                try? await Task.sleep(for: .milliseconds(190))
            }
            guard self.swipe?.generation == generation, !Task.isCancelled else { return }
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil
            // Sizes changed (e.g. a stacked column): images cannot show that,
            // so the real windows move after the fade.
            if let space = instantSpace { self.animateFocus(space: space, byID: self.latestSurvey) }
            self.swipeMetrics["state"] = gone ? "minimized" : (done ? "minimizeUnconfirmed" : "minimizeRefused")
            self.swipeMetrics["minimizeMS"] = (ProcessInfo.processInfo.systemUptime - released) * 1000
            self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
            self.scheduleRefresh()
        }
    }

    /// The minimized window leaves the strip now, as a refresh would remove
    /// it, with focus per `focusAfterClose`. When the survivors keep their
    /// sizes, their images slide into the gap while the real windows are
    /// placed once underneath; returns the slide's targets and duration.
    /// Otherwise (or with animation off) returns nil after the logical
    /// removal, leaving placement to the caller.
    private func collapseGap(after wid: UInt32, state: Swipe) -> (targets: [UInt32: Rect], duration: Double)? {
        guard let session = coordinator.sessions[state.space], isActiveRepresentative(wid) else { return nil }
        let members = Set(session.members(of: wid) ?? [wid])
        let target = neighbourAfterClose(members)
        guard (try? coordinator.removeContainer(containing: wid, classification: Self.tiled)) != nil else { return nil }
        if let target {
            try? session.focus(windowID: target, ownerPID: pidForWindow[target], classification: Self.tiled, ticket: session.ticket)
            closeFocus = (target, ProcessInfo.processInfo.systemUptime + 0.8)
            log("focus after minimize: \(target)")
        }
        reveal(session)
        applied.removeValue(forKey: state.space)
        let duration = options.config.focusScrollDuration ?? 0.22
        guard duration > 0, let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { return nil }
        let targets = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
        // Every survivor needs an image of the right size to slide.
        guard targets.allSatisfy({ id, frame in
            guard let start = state.starts[id] else { return false }
            return abs(start.width - frame.width) <= 2 && abs(start.height - frame.height) <= 2
        }) else { return nil }
        state.overlay.slide(to: targets, duration: duration, easeIn: true)
        apply(space: state.space, byID: state.surveys)
        if let target { _ = raise(target) }
        return (targets, duration)
    }

    /// After a slide under the overlay: wait for the real windows to stop at
    /// their targets (up to 0.4 s), correct the images onto where they
    /// actually landed, and hold two frames for apps to redraw.
    private func finishHandoff(overlay: SnapshotTransition, targets: [UInt32: Rect], generation: UInt64) async {
        var previous: [UInt32: Rect] = [:]
        var result = (settled: false, landing: targets, maxDeviation: 0.0)
        for _ in 0..<16 {
            guard swipe?.generation == generation, !Task.isCancelled else { return }
            var current: [UInt32: Rect] = [:]
            for id in targets.keys {
                guard let element = references[id] else { continue }
                AXUIElementSetMessagingTimeout(element, 0.02)
                if let frame = Diagnostics.frame(element) { current[id] = frame }
                AXUIElementSetMessagingTimeout(element, 0.2)
            }
            result = LiveReconciliation.handoff(previous: previous, current: current, targets: targets)
            if result.settled { break }
            previous = current
            try? await Task.sleep(for: .milliseconds(25))
        }
        if result.maxDeviation > 0.5 {
            overlay.slide(to: result.landing, duration: 0.08)
            try? await Task.sleep(for: .milliseconds(90))
        }
        try? await Task.sleep(for: .milliseconds(34))
    }

    enum NewWindowMethod: String { case menu, key, none }

    /// Opens a new window of the app: its "New Window" menu item when it has
    /// one (it means a window even where ⌘N opens a document or message, and
    /// needs no keyboard focus), else ⌘N while `wid` is its focused window.
    private static func openNewWindow(pid: pid_t, window wid: UInt32) -> NewWindowMethod {
        if let item = newWindowMenuItem(pid: pid),
           AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return .menu }
        return sendCommand(keyN, to: pid, window: wid) ? .key : .none
    }

    /// The app's English "New Window" menu item, else a "New … Window" one
    /// (e.g. Finder's "New Finder Window"; never private or incognito). For
    /// a submenu (Terminal's profiles), its first enabled item. Titles are
    /// localised, so other languages fall back to ⌘N.
    private static func newWindowMenuItem(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        func children(_ element: AXUIElement) -> [AXUIElement] {
            Diagnostics.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        func enabled(_ element: AXUIElement) -> Bool { Diagnostics.attribute(element, kAXEnabledAttribute) as? Bool != false }
        guard let bar = Diagnostics.attribute(application, kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var exact: AXUIElement?, loose: AXUIElement?
        // Skip the Apple menu; look one level into each menu.
        for top in children(bar as! AXUIElement).dropFirst() {
            for menu in children(top) {
                for item in children(menu) where enabled(item) {
                    guard let title = (Diagnostics.attribute(item, kAXTitleAttribute) as? String)?
                        .trimmingCharacters(in: .whitespaces).lowercased() else { continue }
                    if title == "new window" { exact = exact ?? item }
                    else if title.hasPrefix("new "), title.hasSuffix(" window"),
                            !title.contains("private"), !title.contains("incognito") { loose = loose ?? item }
                }
            }
            if exact != nil { break }
        }
        guard let found = exact ?? loose else { return nil }
        if let submenu = children(found).first, let first = children(submenu).first(where: enabled) { return first }
        return found
    }

    /// Committed swipe down with `swipeDown: newWindow`: the app opens a new
    /// window (menu item, else ⌘N) and the overlay fades; the new window is
    /// admitted to the strip like any other.
    private func finishNewWindow(_ state: Swipe, window wid: UInt32) {
        let generation = state.generation, overlay = state.overlay
        let method = pidForWindow[wid].map { Self.openNewWindow(pid: $0, window: wid) } ?? .none
        let sent = method != .none
        if !sent { overlay.retractIndicator(duration: 0.18) }
        swipeMetrics["newWindow"] = method.rawValue
        swipeTask = Task { [weak self] in
            // One frame for the action to land before the fade.
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil
            self.swipeMetrics["state"] = sent ? "newWindow" : "newWindowRefused"
            self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
            self.scheduleRefresh()
        }
    }

    /// Committed tab close: the app closes the front tab under the overlay,
    /// and the overlay fades onto the next tab. A
    /// native tab is pressed shut (⌘W without a close button); a listed
    /// app's in-content tab gets ⌘W. A tab that stays (an unsaved-changes
    /// prompt) is simply revealed again.
    private func finishTabClose(_ state: Swipe, window wid: UInt32, mode: TabClose) {
        let generation = state.generation, overlay = state.overlay
        let released = ProcessInfo.processInfo.systemUptime
        let method: CloseMethod
        switch mode {
        case .native: method = pressClose(wid)
        case .app: method = pidForWindow[wid].map { Self.sendCommandW(to: $0, window: wid) ? .key : .none } ?? .none
        }
        swipeMetrics["closeMethod"] = method.rawValue
        swipeMetrics["tabClose"] = mode.rawValue
        if method == .none { overlay.retractIndicator(duration: 0.18) }
        swipeTask = Task { [weak self] in
            var gone = false
            if method != .none {
                if mode == .native {
                    // The closed tab's window leaves; the next tab is a different one.
                    for _ in 0..<32 {
                        guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
                        if self.destroyedNotified.contains(wid) || !Self.windowOnScreen(wid) { gone = true; break }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                } else {
                    // In-content tabs give no signal; allow one redraw.
                    gone = true
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil
            self.swipeMetrics["state"] = gone ? "tabClosed" : (method == .none ? "noCloseButton" : "closeRefused")
            self.swipeMetrics["closeMS"] = (ProcessInfo.processInfo.systemUptime - released) * 1000
            self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
            self.scheduleRefresh()
        }
    }

    /// Release towards the reducer’s chosen neighbour, or the progress side
    /// for simulations. A rejected commit slides back with no writes.
    func endSwipe(commit requested: Bool, direction requestedDirection: Direction? = nil) {
        guard var state = swipe, state.released == nil else { return }
        let direction: Direction = requestedDirection ?? (state.targetProgress < 0 ? .left : .right)
        let target = state.closing ? state.closeWindow : state.neighbours[direction]
        let commit = requested && (state.closing || requestedDirection != nil || state.targetProgress != 0) && target != nil
        state.releaseDirection = direction
        let settle = max(0.12, options.config.focusScrollDuration ?? 0.22)
        if !state.ready && !state.failed { state.released = commit; swipe = state; return }
        if state.failed {
            swipe = nil
            swipeTask = nil
            scheduleRefresh()
            if commit, state.showsNewWindow, let wid = target, let pid = pidForWindow[wid] {
                _ = Self.openNewWindow(pid: pid, window: wid)
            } else if commit, state.pulling, let wid = target { _ = minimize(wid) }
            else if commit, state.closing, let wid = target {
                if state.showsTabClose && state.tabClose == .app, let pid = pidForWindow[wid] { _ = Self.sendCommandW(to: pid, window: wid) }
                else { _ = pressClose(wid) }
            }
            else if commit { _ = handle(["focus", direction == .left ? "left" : "right"]) }
            return
        }
        state.released = commit
        swipe = state
        let generation = state.generation, space = state.space, overlay = state.overlay
        overlay.stopFrameClock()
        swipeMetrics["trackingFrames"] = state.frames
        swipeMetrics["trackingDroppedFrames"] = state.droppedFrames
        swipeMetrics["trackingMaxFrameMS"] = state.maxFrameMS
        if commit && state.closing { finishClose(state, settle: settle); return }
        guard commit, let wid = target, let session = coordinator.sessions[space],
              let ends = state.ends[direction] else {
            // Drop back from the speed the images had on screen.
            let back = state.progress < 0 ? state.visualVelocity : -state.visualVelocity
            let duration = SlotSwipe.settleDuration(distance: abs(state.progress), speed: back, base: settle)
            let curve = SlotSwipe.settleCurve(speed: back, distance: abs(state.progress), duration: duration)
            // Follow the tracking path back so every image keeps the strip's speed.
            let from = state.progress, path = state
            overlay.slide(along: { u in self.swipeFrames(path, progress: from * (1 - u)) },
                          to: state.starts, duration: duration, curve: curve)
            if state.showsIndicator { overlay.retractIndicator(duration: duration) }
            else if state.closing, let wid = state.closeWindow { overlay.fade(wid, to: 1, duration: duration, curve: curve) }
            swipeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 10))
                guard let self, self.swipe?.generation == generation else { return }
                overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil
                self.swipeMetrics["state"] = "snappedBack"
                self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
                self.scheduleRefresh()
            }
            return
        }
        let destinationProgress = direction == .left ? -1.0 : 1.0
        // Land from the speed the strip had on screen, then slow onto the column.
        let distance = abs(destinationProgress - state.progress)
        let speed = destinationProgress > state.progress ? state.visualVelocity : -state.visualVelocity
        let duration = SlotSwipe.settleDuration(distance: distance, speed: speed, base: settle)
        let from = state.progress, path = state
        // Start the landing first: it runs off the main thread, so the
        // synchronous window writes below cannot freeze it at release.
        overlay.slide(along: { u in
            self.swipeFrames(path, progress: from + (destinationProgress - from) * u)
        }, to: ends, duration: duration, curve: SlotSwipe.settleCurve(speed: speed, distance: distance, duration: duration))
        let released = ProcessInfo.processInfo.systemUptime
        // Same logical result as `focus`; one real placement under the overlay.
        try? session.focus(windowID: wid, ownerPID: pidForWindow[wid], classification: Self.tiled, ticket: session.ticket)
        reveal(session)
        applied.removeValue(forKey: space)
        apply(space: space, byID: state.surveys)
        _ = raise(wid)
        let writesMS = (ProcessInfo.processInfo.systemUptime - released) * 1000
        swipeMetrics["releaseWritesMS"] = writesMS
        swipeTask = Task { [weak self] in
            // The slide began before the writes; wait out only what is left of it.
            try? await Task.sleep(for: .milliseconds(max(0, Int(duration * 1000 - writesMS))))
            // Hand off only once the real windows have stopped moving, then
            // finish the images on the frames they actually took.
            var previous: [UInt32: Rect] = [:]
            var result = (settled: false, landing: ends, maxDeviation: 0.0)
            for _ in 0..<16 {
                guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
                guard NSEvent.pressedMouseButtons == 0 else {
                    self.cancelMotion(); self.refreshOnMouseUp(); return
                }
                var current: [UInt32: Rect] = [:]
                for wid in ends.keys {
                    if let element = self.references[wid] {
                        AXUIElementSetMessagingTimeout(element, 0.02)
                        if let frame = Diagnostics.frame(element) { current[wid] = frame }
                        AXUIElementSetMessagingTimeout(element, 0.2)
                    }
                }
                result = LiveReconciliation.handoff(previous: previous, current: current, targets: ends)
                if result.settled { break }
                previous = current
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard let self, self.swipe?.generation == generation else { return }
            if result.maxDeviation > 0.5 {
                overlay.slide(to: result.landing, duration: 0.08)
                try? await Task.sleep(for: .milliseconds(90))
                guard self.swipe?.generation == generation else { return }
            }
            // AX geometry can settle before WindowServer presents the apps'
            // newly drawn surfaces. Keep the mask for two 60 Hz frames.
            try? await Task.sleep(for: .milliseconds(34))
            guard self.swipe?.generation == generation, !Task.isCancelled else { return }
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil
            self.swipeMetrics["state"] = result.settled ? (result.maxDeviation <= 0.5 ? "completed" : "landedAdjusted") : "handoffUnsettled"
            self.swipeMetrics["handoffMS"] = (ProcessInfo.processInfo.systemUptime - released) * 1000 - duration * 1000
            self.swipeMetrics["landingCorrectionPT"] = result.maxDeviation
            self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
            self.scheduleRefresh()
        }
    }

    /// `paperi msg swipe left|right|up|down [travel]`: the gesture without a trackpad.
    /// Fingers move `travel` (fraction of one slot) over 0.25 s, then lift;
    /// at least half a slot commits.
    private func simulateSwipe(_ direction: Direction, travel: Double) -> [String: Any] {
        let reply = beginSwipe(isSimulation: true)
        guard reply["ok"] as? Bool == true else { return reply }
        if (direction == .up || direction == .down) && !startClosing(pull: direction == .down) {
            cancelSwipe()
            return ["ok": false, "error": direction == .up ? "no focused window on screen to close" : "swipe down is off or no window is focused"]
        }
        let sign = direction == .left ? -1.0 : 1.0
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.swipe != nil else { return }
                let t = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.25)
                self.updateSwipe(sign * travel * t * (2 - t))
                if t >= 1 {
                    self.swipeSimulation?.invalidate(); self.swipeSimulation = nil
                    self.endSwipe(commit: travel >= 0.5)
                }
            }
        }
        swipeSimulation = timer
        RunLoop.main.add(timer, forMode: .common)
        return reply
    }

    private var applied: [UInt64: [Placement]] = [:]

    private func apply(space: UInt64, byID: [UInt32: Survey]) {
        guard let session = coordinator.sessions[space],
              let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { return }
        let forced = forceApply || ProcessInfo.processInfo.systemUptime < forceUntil
        // Unchanged layout: skip writes (step 7b clears this for moved windows).
        if !forced, applied[space] == placements { return }
        var allConfirmed = true
        var unresponsive: Set<pid_t> = []
        let tucked = LiveReconciliation.tuck(placements.map { ($0.windowID, $0.frame) },
                                             canvas: session.canvas, screenInset: options.outerGap)
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
            // Displays are stacked (see DisplayArrangement), so a column past a
            // side edge never overlaps another display.
            let target = tucked[wid] ?? placement.frame
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

    /// Window IDs in stacking order. Only the on-screen list is ordered front
    /// to back (`.optionAll` is not); managed windows always keep a sliver on screen.
    private static func frontToBack() -> [UInt32] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
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
    private func write(_ frame: Rect, to element: AXUIElement) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        let result = Self.write(frame, to: element)
        if commandStarted > 0 {
            if firstWriteMS == nil { firstWriteMS = (start - commandStarted) * 1000 }
            finalWriteMS = (ProcessInfo.processInfo.systemUptime - commandStarted) * 1000
        }
        axWriteCalls += 3; axWriteMS += (ProcessInfo.processInfo.systemUptime - start) * 1000
        return result
    }

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
        case "status" where paused:
            let gestureConflicts = GestureConflict.checkLive(fingers: options.config.gesture.fingers)
            let gestureStatus: [String: Any] = [
                "enabled": false,
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
        default:
            return fail("unknown command \(verb)")
        }
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
        let gestureConflicts = GestureConflict.checkLive(fingers: options.config.gesture.fingers)
        let gestureEnabled = options.config.gesture.enabled && gestureConflicts.isEmpty
        let gestureStatus: [String: Any] = [
            "enabled": gestureEnabled,
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
