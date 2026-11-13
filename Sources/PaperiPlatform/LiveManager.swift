import AppKit
@preconcurrency import ApplicationServices
import PaperiBridge
import PaperiCore

/// Live manager for real windows of configured applications.
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
    var recorder: EventRecorder!
    var references: [UInt32: AXUIElement] = [:]
    var pidForWindow: [UInt32: pid_t] = [:]
    var journal: [UInt32: (pid: pid_t, frame: Rect)] = [:]
    var userFloating: Set<UInt32> = []
    var destroyedNotified: Set<UInt32> = []
    /// Neighbour chosen when the focused window closed (`focusAfterClose`). It
    /// overrides the OS focus briefly, while its raise and app activation land.
    var closeFocus: (window: UInt32, until: Double)?
    var expected: [UInt32: (frame: Rect, at: Double)] = [:]
    /// Managed window the user is dragging (moved while the left button is
    /// down). It is not written until mouse up, so it follows the pointer.
    /// While the pointer is over a neighbouring window (adjacent column or
    /// same stack) it is highlighted with a preview of the drop armed by the
    /// pointer's zone (`hovered`); releasing there swaps, stacks or splits out.
    struct Drag {
        let windowID: UInt32; let space: UInt64; let targets: [SwapTarget]
        var hovered: (target: SwapTarget, action: DropAction)?
    }
    var drag: Drag?
    var dragging: UInt32? { drag?.windowID }
    var dragTimer: Timer?
    let highlight = DropHighlight()
    let windowIndicators = WindowIndicators()
    var mouseUpWatch = false
    /// Last off-slot frame acted on per window, so an app that clamps its
    /// position is rewritten once rather than on every refresh.
    var displaced: [UInt32: Rect] = [:]
    var refreshScheduled = false
    /// Apps whose AX requests timed out are skipped briefly so one hung app
    /// cannot stall management of every other app.
    var slowUntil: [pid_t: Double] = [:]
    var forceApply = true
    /// After an active-Space change, refreshes re-check real frames for a short
    /// while: macOS and apps (e.g. leaving a fullscreen Space) may move
    /// off-canvas windows on screen once their Space is shown again.
    var forceUntil: Double = 0
    /// Last column width of every managed member, kept after the window leaves
    /// the strip (minimize, hide, fullscreen, float) so it returns at that
    /// width, as in PaperWM.
    var preferredWidth: [UInt32: Double] = [:]
    var timer: Timer?
    var workspaceTokens: [NSObjectProtocol] = []
    private(set) var running = false
    var busy = false
    public private(set) var lastRefreshMS: Double = 0

    static let tiled = WindowPolicy.classify(WindowFacts(bundleID: "live", role: "AXWindow",
        subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true, level: 0))

    public init(options: Options) {
        self.options = options
        coordinator = DisplaySpaceCoordinator(ownerPIDs: [], displays: [])
        windowIndicators.onSelect = { [weak self] window, space in
            self?.focusThumbnail(window, in: space)
        }
        windowIndicators.onMove = { [weak self] window, position, space in
            self?.moveThumbnail(window, to: position, in: space)
        }
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

    /// Stops management and restores admission geometry, retaining unresolved recovery entries.
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
        windowIndicators.hide()
        coordinator.stop()
        let teardown = recorder.stop()
        if keepJournal { return ["stopped": true, "sourcesStillInstalled": teardown["sourcesStillInstalled"] ?? 0] }
        var result = restoreJournal(restore ?? options.restoreOnStop)
        result["stopped"] = true
        result["sourcesStillInstalled"] = teardown["sourcesStillInstalled"] ?? 0
        return result
    }

    func restoreJournal(_ restore: Bool) -> [String: Any] {
        if !restore {
            journal.removeAll()
            do { if FileManager.default.fileExists(atPath: options.journalURL.path) { try FileManager.default.removeItem(at: options.journalURL) } }
            catch { return ["restored": 0, "restoreFailed": 0, "journal": "persistenceFailed", "error": String(describing: error)] }
            return ["restored": 0, "restoreFailed": 0]
        }
        let entries = journal.map { id, entry in
            RestoreEntry(windowID: id, pid: entry.pid, frame: [entry.frame.x, entry.frame.y, entry.frame.width, entry.frame.height])
        }
        let result = Self.restoreEntries(entries, url: options.journalURL) { wid, pid in
            self.references[wid] ?? self.findWindow(wid, pid: pid)
        }
        journal.removeAll()
        return result
    }

    @discardableResult public static func restore(journalURL: URL = defaultJournalURL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return ["restored": 0, "restoreFailed": 0, "journal": "absent"]
        }
        do {
            let entries = try JSONDecoder().decode([RestoreEntry].self, from: Data(contentsOf: journalURL))
            return restoreEntries(entries, url: journalURL)
        } catch {
            return ["restored": 0, "restoreFailed": 0, "journal": "unreadable", "error": String(describing: error)]
        }
    }

    static func restoreEntries(_ entries: [RestoreEntry], url: URL,
                               lookup: (UInt32, pid_t) -> AXUIElement? = { findWindow($0, pid: $1) }) -> [String: Any] {
        // WindowServer ownership distinguishes vanished windows from unavailable AX enumeration.
        let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        return LiveRestoration.run(entries: entries, url: url) { entry, frame in
            guard let rows else { return .failed("WindowServer inventory unavailable") }
            guard rows.contains(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == entry.windowID &&
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == entry.pid
            }) else { return .gone }
            guard let element = lookup(entry.windowID, entry.pid) else {
                return .failed("AX window lookup unavailable")
            }
            AXUIElementSetMessagingTimeout(element, 0.2)
            let errors = writeErrors(frame, to: element)
            guard errors.allSatisfy({ $0 == 0 }) else { return .failed("AX size/position/size errors: \(errors)") }
            guard let actual = Diagnostics.frame(element),
                  abs(actual.x - frame.x) <= 2, abs(actual.y - frame.y) <= 2,
                  abs(actual.width - frame.width) <= 2, abs(actual.height - frame.height) <= 2 else {
                return .adjusted("AX writes succeeded; final frame differs or is unavailable (app constraints, display changes, or asynchronous updates)")
            }
            return .restored
        }
    }

    func restoreStaleJournal() throws {
        let result = Self.restore(journalURL: options.journalURL)
        guard ["absent", "removed"].contains(result["journal"] as? String ?? "") else {
            throw NSError(domain: "Paperi.Restoration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Window recovery remains unresolved: \(result). Retry paperi restore before starting management."])
        }
        log("restored stale journal: \(result)")
    }

    // MARK: events

    func receive(_ event: [String: Any]) {
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

    func activeSpaceChanged() {
        windowIndicators.hide()
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

    /// Follows the pointer during a drag: highlights the neighbour under it,
    /// previewing the drop its zone arms, and on mouse up finishes the drag
    /// and places the window.
    func trackDrag() {
        guard running, var current = drag else { endDrag(); return }
        if NSEvent.pressedMouseButtons & 1 == 0 { finishDrag(); refresh(); return }
        let pointer = NSEvent.mouseLocation
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let (x, y) = (Double(pointer.x), primaryHeight - Double(pointer.y))
        let hit = current.targets.lazy.compactMap { t in t.action(x: x, y: y).map { (target: t, action: $0) } }.first
        guard hit?.target != current.hovered?.target || hit?.action != current.hovered?.action else { return }
        current.hovered = hit; drag = current
        if let hit {
            highlight.show(hit.target, action: hit.action, color: options.config.swapHighlightColor)
        } else {
            highlight.hide()
        }
    }

    /// Applies the drop armed over the hovered window, if any, and forces a
    /// placement pass.
    func finishDrag() {
        guard let current = drag else { endDrag(); return }
        endDrag()
        forceApply = true
        guard let (target, action) = current.hovered, let session = coordinator.sessions[current.space] else { return }
        if session.drop(windowID: current.windowID, on: target.slotID, action: action, ticket: session.ticket) {
            log("dropped \(current.windowID) on slot \(target.slotID) (\(action.rawValue)) after drag")
        }
    }

    func endDrag() {
        drag = nil
        dragTimer?.invalidate(); dragTimer = nil
        highlight.hide()
    }

    /// No AX event may follow a release, so poll for mouse up and refresh once
    /// to apply what was deferred (step 8).
    func refreshOnMouseUp() {
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

    func topologies() -> [DisplaySpaceTopology] {
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

    func allowlistedApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { Self.considered($0, config: options.config) }
    }

    /// Apps worth an AX survey this pass: those with a normal-level window on
    /// screen (cheap window-server query) or with containers already managed.
    /// Everything else (dozens of background apps) costs nothing.
    func appsToSurvey(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
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

    static func windowSpace(_ wid: UInt32) -> UInt64? {
        guard let spaces = paperi_copy_window_spaces(wid) as? [NSNumber], spaces.count == 1 else { return nil }
        return spaces[0].uint64Value
    }

    func survey(_ app: NSRunningApplication, levels: [UInt32: Int]) -> [Survey] {
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
    static func hasFullScreenButton(_ window: AXUIElement) -> Bool? {
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
        defer { windowIndicators.update(coordinator, mode: options.config.bottomDotsVisibility) }
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
        let layoutsBeforeClose = coordinator.sessions.mapValues { $0.state.layout }
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
            if !mouseDown, closedSpaces.contains(space), let previous = layoutsBeforeClose[space],
               let offset = LiveReconciliation.offsetAfterTrailingClose(previous: previous,
                    current: session.state.layout, canvas: session.canvas, gap: options.gap) {
                session.setOffset(offset, ticket: session.ticket)
            }
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
        // tracked until mouse up (trackDrag): released over a neighbouring
        // window it swaps, stacks or splits out (by zone), then snaps into its slot.
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
    func neighbourAfterClose(_ gone: Set<UInt32>) -> UInt32? {
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

    func isActiveRepresentative(_ wid: UInt32) -> Bool {
        guard let session = coordinator.session(containing: wid), let slot = session.slots[wid],
              let loc = session.state.layout.index(of: slot) else { return false }
        return session.state.layout.columns[loc.column].slots[loc.row].activeMember == wid
    }

    func admitSingleton(_ wid: UInt32, pid: pid_t, space: UInt64, byID: [UInt32: Survey]) {
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
    func admissionWidth(_ members: [UInt32], active: UInt32, byID: [UInt32: Survey], canvas: Rect) -> Double? {
        let own = ([active] + members).lazy.compactMap({ self.preferredWidth[$0] }).first
            ?? byID[active]?.frame.flatMap { $0.isValid ? $0.width : nil }
        return own.map { min($0, maxColumnWidth(canvas)) }
    }

    func maxColumnWidth(_ canvas: Rect) -> Double {
        Layout.maxColumnWidth(in: canvas, edgeMargin: options.gap)
    }

    func rememberWidths() {
        for session in coordinator.sessions.values {
            for column in session.state.layout.columns {
                for slot in column.slots { for member in slot.members { preferredWidth[member] = column.width } }
            }
        }
    }

    func removeMembers(_ gone: Set<UInt32>) {
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

    func reveal(_ session: ScopedLayoutSession) {
        var layout = session.state.layout
        if (try? layout.reveal(in: session.canvas, gap: options.gap)) == true {
            session.setOffset(layout.offset, ticket: session.ticket)
        }
    }

    // MARK: effects

    var phaseMS: [String: Double] = [:]
    var axWriteCalls = 0
    var axWriteMS = 0.0
    var latestSurvey: [UInt32: Survey] = [:]
    var motionBegan: Double?
    var motionFailed: Set<UInt32> = []
    var motionBlocked: Set<UInt32> = []
    var motionTicks = 0
    var motionSpace: UInt64?
    var motionTimer: Timer?
    var motionBounce: Direction?
    var motionGeneration: UInt64 = 0
    var motionFrames: [UInt32: Rect] = [:]
    var commandStarted = 0.0
    var firstWriteMS: Double?
    var finalWriteMS: Double?
    var confirmedMS: Double?
    var tickMS = 0.0
    var missedTicks = 0

    // MARK: swipe state (logic in LiveManager+Swipe.swift)

    var swipe: Swipe?
    var swipeTask: Task<Void, Never>?
    var neighbourTask: Task<Void, Never>?
    var swipeGuard: Timer?
    var swipeSimulation: Timer?
    var swipeMetrics: [String: Any] = [:]
    var swipeBegan = 0.0
    var touchSource: TouchSource?
    var slotSwipe: SlotSwipe?
    var lastGestureConflicts: [String]?
    /// The current touch sequence began during a catchable landing and has
    /// not locked an axis yet; the landing goes on until it locks horizontally.
    var catchPending = false
    /// The current touch sequence began (or locked vertically) while an
    /// animation was on screen. Its reducer keeps following the fingers; the
    /// gesture takes effect when the animation has finished.
    var gestureDeferred = false
    /// That sequence was released meanwhile with this decision.
    var deferredEnd: SlotSwipe.Decision?
    var resumingGesture = false
    var standaloneOverlay: SnapshotTransition?
    var standaloneAction: LiveConfig.SwipeDownAction = .none
    var standaloneClose = false
    var standalonePull = false
    var standaloneHintDirection = CGVector(dx: 0, dy: -1)

    var applied: [UInt64: [Placement]] = [:]

    func apply(space: UInt64, byID: [UInt32: Survey]) {
        guard let session = coordinator.sessions[space],
              let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { return }
        let forced = forceApply || ProcessInfo.processInfo.systemUptime < forceUntil
        // Unchanged layout: skip writes (step 7b clears this for moved windows).
        if !forced, applied[space] == placements { return }
        var allConfirmed = true
        var unresponsive: Set<pid_t> = []
        let tucked = LiveReconciliation.tuck(LiveReconciliation.edgeItems(placements),
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
    static func frontToBack() -> [UInt32] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? UInt32 }
    }

    func matches(_ a: Rect, _ b: Rect) -> Bool {
        zip([a.x, a.y, a.width, a.height], [b.x, b.y, b.width, b.height]).allSatisfy { abs($0 - $1) <= 2 }
    }

    @discardableResult static func write(_ frame: Rect, to element: AXUIElement) -> Bool {
        writeErrors(frame, to: element).allSatisfy { $0 == 0 }
    }

    static func writeErrors(_ frame: Rect, to element: AXUIElement) -> [Int32] {
        var point = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return [AXError.illegalArgument.rawValue] }
        // Size, position, size: shrinking first avoids edge clamping; the
        // second size handles apps that clamp size against the old position.
        var errors: [Int32] = []
        for (name, value) in [(kAXSizeAttribute, s), (kAXPositionAttribute, p), (kAXSizeAttribute, s)] {
            errors.append(AXUIElementSetAttributeValue(element, name as CFString, value).rawValue)
        }
        return errors
    }
    func write(_ frame: Rect, to element: AXUIElement) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        let result = Self.write(frame, to: element)
        if commandStarted > 0 {
            if firstWriteMS == nil { firstWriteMS = (start - commandStarted) * 1000 }
            finalWriteMS = (ProcessInfo.processInfo.systemUptime - commandStarted) * 1000
        }
        axWriteCalls += 3; axWriteMS += (ProcessInfo.processInfo.systemUptime - start) * 1000
        return result
    }

    static func findWindow(_ wid: UInt32, pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return (Diagnostics.attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? [])
            .first { paperi_window_id($0) == wid }
    }
    func findWindow(_ wid: UInt32, pid: pid_t) -> AXUIElement? { Self.findWindow(wid, pid: pid) }

    // MARK: journal

    func remember(_ wid: UInt32, pid: pid_t, frame: Rect?) {
        guard let frame, frame.isValid, journal[wid] == nil else { return }
        journal[wid] = (pid, frame)
        persistJournal()
    }

    func persistJournal() {
        let rows = journal.map { wid, entry in
            RestoreEntry(windowID: wid, pid: entry.pid, frame: [entry.frame.x, entry.frame.y, entry.frame.width, entry.frame.height])
        }
        do {
            try FileManager.default.createDirectory(at: options.journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(rows)
            try data.write(to: options.journalURL, options: .atomic)
        } catch { log("cannot persist restore journal: \(error)") }
    }

    func log(_ message: String) {
        guard options.verbose else { return }
        let t = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[paperi \(t)] \(message)\n".utf8))
    }

}
