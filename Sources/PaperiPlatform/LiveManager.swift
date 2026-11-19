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
    var minimizes = MinimizeTracker()
    var pendingReflows = PendingReflows()
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
    // Gap resize (LiveManager+Dividers.swift).
    struct DividerDrag {
        let space: UInt64; let divider: Divider
        /// Pointer minus the gap centre along the drag axis at mouse down
        /// (for a column edge, plus the strip's scroll against the wall since).
        var grab: Double
        /// Smallest / largest size along the drag axis each slot's app
        /// accepted, learned when it refuses a write (slot ID → points).
        var minimums: [String: Double] = [:]
        var maximums: [String: Double] = [:]
        /// Latest pointer coordinate along the drag axis.
        var along: Double
    }
    let frameWriter = FrameWriter()
    let dividerHandle = DividerHandle()
    /// The gap under the pointer: as laid out, and as actually on screen.
    var dividerHover: (space: UInt64, region: DividerRegion, shown: DividerRegion)?
    var dividerDrag: DividerDrag?
    var dividerMonitors: [Any] = []
    /// A Shift + trackpad edge resize (LiveManager+EdgeResize.swift).
    var edgeResize: EdgeResize?
    /// A ⌘ + trackpad swipe (LiveManager+CommandSwipe.swift).
    var commandSwipe: CommandSwipe?
    let edgeResizeIndicator = EdgeResizeIndicator()
    var mouseUpWatch = false
    /// Last off-slot frame acted on per window, so an app that clamps its
    /// position is rewritten once rather than on every refresh.
    var displaced: [UInt32: Rect] = [:]
    var refreshScheduled = false
    /// Apps whose AX requests timed out are skipped briefly so one hung app
    /// cannot stall management of every other app.
    var responsiveness = AppResponsiveness()
    var forceApply = true
    /// After an active-Space change, refreshes re-check real frames for a short
    /// while: macOS and apps (e.g. leaving a fullscreen Space) may move
    /// off-canvas windows on screen once their Space is shown again.
    var forceUntil: Double = 0
    /// Last column width of every managed member, kept after the window leaves
    /// the strip (minimize, hide, fullscreen, float) so it returns at that
    /// width, as in PaperWM.
    var preferredWidth: [UInt32: Double] = [:]
    /// Windows seen fullscreen or with a fullscreen button. Apps with custom
    /// window controls rebuild their title bar when leaving fullscreen and
    /// may then report no fullscreen button; such a window is still a
    /// document, not a utility window, so it returns to the strip.
    var fullScreenCapable: Set<UInt32> = []
    /// WindowServer IDs seen by the previous pass; nil until the first pass,
    /// so windows present at start (or resume) are never treated as new.
    var knownWindows: Set<UInt32>?
    /// Windows that appeared since start, with when they appeared. Admission
    /// consumes the entry, so only genuinely new windows auto-stack, never
    /// ones returning from minimize, hide, fullscreen or float.
    var newWindows: [UInt32: Double] = [:]
    /// Windows of a column just auto-stacked, until when their height
    /// mismatches are re-written rather than adopted as a divider drag: an
    /// app may apply the shrink late (or drop it while opening the new
    /// window), which must not undo the even split.
    var autoStackSettling: [UInt32: Double] = [:]
    /// Windows that keep a rounded size for their target (see FrameConstraints).
    var frameConstraints = FrameConstraints()
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
        destroyedNotified.removeAll(); minimizes = MinimizeTracker(); pendingReflows = PendingReflows()
        closeFocus = nil; responsiveness = AppResponsiveness(); forceApply = true
        knownWindows = nil; newWindows.removeAll(); autoStackSettling.removeAll(); frameConstraints = FrameConstraints()
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
        startDividers()
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
        timer?.invalidate(); timer = nil; endDrag(); stopDividers()
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
        // The recorder reports an unresolved window as 0, never as a missing key.
        let eventWindow = (event["windowID"] as? UInt32).flatMap { $0 == 0 ? nil : $0 }
        if let pid = event["pid"] as? pid_t, name.hasPrefix("AX") {
            responsiveness.heard(pid, now: ProcessInfo.processInfo.systemUptime)
        }
        if name == kAXUIElementDestroyedNotification, let wid = eventWindow {
            minimizes.forget(wid)
            // The window a swipe-up is closing: its release finishes the overlay.
            if let state = swipe, state.closing, state.released == true, state.closeWindow == wid {
                destroyedNotified.insert(wid)
                return
            }
            // Input-method popups and our own overlays are destroyed during
            // normal focus changes. They do not invalidate the managed strip.
            if coordinator.spaceForWindow[wid] != nil || swipe?.surveys[wid] != nil {
                cancelMotion(); motionFrames.removeAll()
                destroyedNotified.insert(wid)
            }
        }
        let presentationChanged = [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification].contains(name)
        if name == kAXWindowDeminiaturizedNotification {
            // A restored window may not be listed or ready right away, and no
            // other event follows. Re-check until it is back in the strip.
            for delay in [0.3, 0.7, 1.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let wid = eventWindow, self.coordinator.spaceForWindow[wid] != nil { return }
                        self.scheduleRefresh()
                    }
                }
            }
        }
        if presentationChanged {
            // The fast focus path uses cached policy facts. Never animate or
            // write from those facts after native presentation has changed.
            if let wid = eventWindow {
                latestSurvey.removeValue(forKey: wid)
                if name == kAXWindowMiniaturizedNotification {
                    if pidForWindow[wid] != nil { noteMinimizing(wid) { $0.minimizeNotified(wid) } }
                } else { minimizes.restoreNotified(wid) }
            } else { latestSurvey.removeAll() }
        }
        let ownMinimize = name == kAXWindowMiniaturizedNotification && swipe.map {
            $0.pulling && $0.pullAction == .minimize && $0.released == true && $0.closeWindow == event["windowID"] as? UInt32
        } == true
        // ⌘N from a released new-window swipe opens a window under the overlay.
        let ownNewWindow = name == kAXWindowCreatedNotification && swipe.map { $0.showsNewWindow && $0.released == true } == true
        if motionActive && !ownMinimize && !ownNewWindow && [kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                                            kAXWindowCreatedNotification].contains(name),
           let pid = event["pid"] as? pid_t {
            let managedOwner = pidForWindow.values.contains(pid) || NSRunningApplication(processIdentifier: pid).map {
                Self.considered($0, config: options.config)
            } == true
            let affectsStrip = eventWindow.map { coordinator.spaceForWindow[$0] != nil || swipe?.surveys[$0] != nil }
            if LiveReconciliation.presentationInterruptsMotion(isMinimize: name == kAXWindowMiniaturizedNotification,
                managedOwner: managedOwner, affectsStrip: affectsStrip) {
                cancelMotion(); motionFrames.removeAll()
            }
        }
        if name == kAXResizedNotification, let state = swipe, state.released == nil,
           eventWindow.map({ state.surveys[$0] != nil }) ?? true {
            cancelMotion(); motionFrames.removeAll()
        }
        if name == kAXMovedNotification || name == kAXResizedNotification {
            // Our own writes echo back; refresh decides whether it was external.
        }
        if name == "identitiesRenewed" {
            log("renewed exhausted \(event["table"] ?? "") identity table for pid \(event["pid"] ?? "")")
            return
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
        guard let element = references[current.windowID], let actual = Diagnostics.frame(element),
              let baseline = expected[current.windowID]?.frame,
              abs(actual.width - baseline.width) <= 2,
              abs(actual.height - baseline.height) <= 2 else { return }
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
    /// Owners playing a minimize Paperi requested: blocked until the Dock
    /// effect ends, so surveying them would only cost a timeout.
    func minimizingOwners(now: Double) -> Set<pid_t> {
        Set(minimizes.pendingWindows(now: now).compactMap { pidForWindow[$0] })
    }

    func appsToSurvey(_ apps: [NSRunningApplication]) -> [NSRunningApplication] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var onScreen: Set<pid_t> = []
        for row in rows where (row[kCGWindowLayer as String] as? Int ?? -1) == 0 {
            if let pid = row[kCGWindowOwnerPID as String] as? pid_t { onScreen.insert(pid) }
        }
        let managedOwners = Set(coordinator.spaceForWindow.keys.compactMap { pidForWindow[$0] })
        let now = ProcessInfo.processInfo.systemUptime
        let minimizing = minimizingOwners(now: now)
        return apps.filter { app in
            let pid = app.processIdentifier
            guard responsiveness.available(pid, now: now), !minimizing.contains(pid) else { return false }
            return onScreen.contains(pid) || managedOwners.contains(pid)
        }
    }

    static func windowSpace(_ wid: UInt32) -> UInt64? {
        guard let spaces = paperi_copy_window_spaces(wid) as? [NSNumber], spaces.count == 1 else { return nil }
        return spaces[0].uint64Value
    }

    /// Nil when the app did not answer: unknown, not "has no windows".
    func survey(_ app: NSRunningApplication, levels: [UInt32: Int]) -> [Survey]? {
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
        if error == .cannotComplete {
            let delay = responsiveness.timedOut(pid, now: ProcessInfo.processInfo.systemUptime)
            log("\(app.bundleIdentifier ?? "pid \(pid)") did not answer AX; skipping for \(delay) s")
            // The 1 s timer covers longer backoffs.
            if delay < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
            }
            return nil
        }
        responsiveness.answered(pid)
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
            let fullscreen = Diagnostics.attribute(ref, "AXFullScreen") as? Bool ?? false
            var fullScreenButton = Self.hasFullScreenButton(ref)
            if fullscreen || fullScreenButton == true { fullScreenCapable.insert(wid) }
            else if fullScreenButton == false && fullScreenCapable.contains(wid) { fullScreenButton = true }
            let facts = WindowFacts(bundleID: app.bundleIdentifier ?? "",
                role: Diagnostics.attribute(ref, kAXRoleAttribute) as? String,
                subrole: Diagnostics.attribute(ref, kAXSubroleAttribute) as? String,
                isRoot: parent.map { CFEqual($0, application) },
                movable: moveResult == .success ? move.boolValue : nil,
                resizable: resizeResult == .success ? resize.boolValue : nil,
                fullscreen: fullscreen,
                minimized: Diagnostics.attribute(ref, kAXMinimizedAttribute) as? Bool,
                level: levels[wid], hasFullScreenButton: fullScreenButton)
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
        defer {
            windowIndicators.update(coordinator, mode: options.config.bottomDotsVisibility)
            updateDividerHover()
        }
        // A gap drag writes its own frames; reconcile once it ends. A
        // trackpad edge resize holds the strip from the moment it is armed.
        if dividerDrag != nil || edgeResize != nil { return }
        if motionActive { return }
        minimizes.expire(now: ProcessInfo.processInfo.systemUptime)
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
        noteNewWindows(Set(levels.keys), now: started)
        let apps = allowlistedApps()
        let livePIDs = Set(apps.map(\.processIdentifier))
        for app in apps { coordinator.addOwner(app.processIdentifier) }
        minimizes.retain { pidForWindow[$0].map(livePIDs.contains) == true }
        responsiveness.retain(livePIDs)

        // 1. Destruction: native notification, window-server absence, or owner exit.
        let managed = Set(coordinator.spaceForWindow.keys)
        let gone = managed.filter { wid in
            destroyedNotified.contains(wid) || (levels[wid] == nil && !minimizes.contains(wid)) || pidForWindow[wid].map { !livePIDs.contains($0) } ?? true
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
        fullScreenCapable = fullScreenCapable.filter { levels[$0] != nil }

        let discoveryStart = ProcessInfo.processInfo.systemUptime
        // 2. Survey allowlisted apps.
        var surveys: [pid_t: [Survey]] = [:]
        let minimizingOwners = minimizingOwners(now: discoveryStart)
        for app in appsToSurvey(apps) where !app.isHidden {
            if let rows = survey(app, levels: levels) { surveys[app.processIdentifier] = rows }
        }
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
        // Decisions use only fresh rows. An app that did not answer (timed
        // out or backed off) still has its windows: keep their last rows as
        // the cache, so animations have geometry for its managed windows.
        let byID = Dictionary(surveys.values.flatMap { $0 }.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let hiddenPIDs = Set(apps.filter(\.isHidden).map(\.processIdentifier))
        let carried = latestSurvey.filter { wid, row in
            surveys[row.pid] == nil && livePIDs.contains(row.pid) && !hiddenPIDs.contains(row.pid)
                && coordinator.spaceForWindow[wid] != nil
        }

        phaseMS["discovery"] = (ProcessInfo.processInfo.systemUptime - discoveryStart) * 1000
        latestSurvey = byID.merging(carried) { fresh, _ in fresh }
        let topologyStart = ProcessInfo.processInfo.systemUptime

        // 3. Definitive state changes (minimized, fullscreen, floated by the
        // user or a rule) leave the strip. Transient metadata, e.g. a sheet
        // making its parent temporarily non-movable, keeps the slot.
        // A minimized window leaves like a closed one: the survivors close the
        // gap animated, and focus follows `focusAfterClose`.
        let minimized = Set(byID.filter { $0.value.facts.minimized == true }.keys)
            .union(minimizes.notified).filter { coordinator.spaceForWindow[$0] != nil && isActiveRepresentative($0) }
        if !minimized.isEmpty {
            let members = Set(minimized.flatMap { coordinator.session(containing: $0)?.members(of: $0) ?? [$0] })
            closedSpaces.formUnion(minimized.compactMap { coordinator.spaceForWindow[$0] })
            if closeTarget == nil, let target = neighbourAfterClose(members) {
                closeTarget = target
                closeFocus = (target, ProcessInfo.processInfo.systemUptime + 0.8)
                log("focus after minimize: \(target)")
            }
        }
        for wid in minimized { _ = try? coordinator.removeContainer(containing: wid, classification: Self.tiled) }
        // Once the survey confirms the event, ordinary observation owns the
        // state again, including recovery from a missed restore notification.
        for (wid, row) in byID { minimizes.observe(wid, minimized: row.facts.minimized) }
        for (wid, row) in byID where coordinator.spaceForWindow[wid] != nil &&
            (row.facts.fullscreen == true || row.floatRequested) {
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
            let singletonApp = options.config.usesSingletonWindows(bundleID: app.bundleIdentifier)
            let relevant = rows.contains { row in row.spaceID.map(activeSpaces.contains) == true &&
                (row.classification.eligibility == .tiled || coordinator.spaceForWindow[row.windowID] != nil) }
            guard relevant else { continue }
            let strictTabs = options.config.usesStrictTabDetection(bundleID: app.bundleIdentifier)
            let evidence = singletonApp ? nil
                : (recorder.tabEvidence(processID: pid, strict: strictTabs)["applications"] as? [[String: Any]])?.first
            for space in activeSpaces {
                guard let session = coordinator.sessions[space] else { continue }
                let candidates = Set(rows.filter {
                    $0.spaceID == space && $0.classification.eligibility == .tiled && !minimizes.contains($0.windowID)
                        && coordinator.spaceForWindow[$0.windowID] == nil
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
                        autoStack(group.active, newMembers: group.members, space: space)
                    }
                }
                for wid in NativeTabMembership.inspectSingletons(evidence) where remaining.contains(wid) {
                    admitSingleton(wid, pid: pid, space: space, byID: byID)
                }
            }
        }

        phaseMS["topology"] = (ProcessInfo.processInfo.systemUptime - topologyStart) * 1000
        let layoutStart = ProcessInfo.processInfo.systemUptime
        pendingReflows.record(spaces: closedSpaces, layouts: layoutsBeforeClose)
        closedSpaces.formUnion(pendingReflows.layouts.keys)

        // Spaces waiting for an owner to confirm Paperi's minimize request:
        // state is reconciled, but their focus, adoption and writes wait.
        let heldSpaces = minimizes.pendingSpaces(now: ProcessInfo.processInfo.systemUptime)

        // 6. Focus: only an allowlisted, managed representative enables commands.
        // An app playing a minimize Paperi requested gives no focus evidence:
        // the read would time out, and the fallback below would pick the
        // sibling it keeps behind, overriding `focusAfterClose`. Other slow
        // apps keep the fallback (see STATUS: activation without a click).
        let front = NSWorkspace.shared.frontmostApplication
        let frontUnanswered = front.map { minimizingOwners.contains($0.processIdentifier) } == true
        var focusedWindow: UInt32?
        var hasFocusedControl = false
        if let front, livePIDs.contains(front.processIdentifier), !frontUnanswered {
            let application = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            if let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = value as! AXUIElement
                focusedWindow = paperi_window_id(element)
            }
            if focusedWindow == nil,
               let value = Diagnostics.attribute(application, kAXFocusedUIElementAttribute),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = value as! AXUIElement
                // A menu search field can own keyboard focus without an AX
                // focused window. Do not turn that into a window activation.
                hasFocusedControl = Diagnostics.attribute(element, kAXRoleAttribute) as? String != kAXApplicationRole
            }
        }
        // An app activated without a click (notification, Dock, ⌘-Tab, `open`)
        // whose windows are all parked off-canvas often has no focused or main
        // window. Treat its frontmost managed window as focused so the strip
        // reveals it, and raise it after placement so it takes key focus.
        var raiseAfterApply: UInt32?
        if let front, livePIDs.contains(front.processIdentifier), !frontUnanswered,
           LiveReconciliation.shouldRecoverWindowFocus(focusedWindow: focusedWindow, hasFocusedControl: hasFocusedControl) {
            let pid = front.processIdentifier
            focusedWindow = Self.frontToBack().first { id in
                self.pidForWindow[id] == pid && self.coordinator.spaceForWindow[id].map(activeSpaces.contains) == true
                    && self.isActiveRepresentative(id)
            }
            raiseAfterApply = focusedWindow
        }
        var focusedPID = front?.processIdentifier
        var focusKnown = !frontUnanswered
        if let hold = closeFocus {
            // A click (or the target being reached, gone, or overdue) ends the hold.
            if mouseDown || focusedWindow == hold.window || ProcessInfo.processInfo.systemUptime > hold.until
                || !isActiveRepresentative(hold.window) || pidForWindow[hold.window] == nil {
                closeFocus = nil
            } else {
                focusedWindow = hold.window; focusedPID = pidForWindow[hold.window]
                raiseAfterApply = nil; focusKnown = true
            }
        }
        var focusAnimationSpace: UInt64?
        for (space, session) in coordinator.sessions where activeSpaces.contains(space) && !heldSpaces.contains(space) {
            let previousOffset = session.state.layout.offset
            let owned = focusedWindow.flatMap { session.slots[$0] != nil ? $0 : nil }
            let classification = owned != nil ? Self.tiled : WindowPolicy.classify(WindowFacts(bundleID: "foreign"))
            if focusKnown {
                try? session.focus(windowID: owned, ownerPID: owned != nil ? focusedPID : nil,
                                   classification: classification, ticket: session.ticket)
            }
            if !mouseDown, closedSpaces.contains(space), let previous = pendingReflows.layouts[space],
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
        if let arrival = spaceArrival {
            if ProcessInfo.processInfo.systemUptime > arrival.until {
                spaceArrival = nil
            } else if activeSpaces.contains(arrival.space), !heldSpaces.contains(arrival.space), !mouseDown {
                spaceArrival = nil
                if focusAnimationSpace == nil, !forceApply, ProcessInfo.processInfo.systemUptime >= forceUntil {
                    focusAnimationSpace = arrival.space
                }
            }
        }
        if focusAnimationSpace == nil, !forceApply, ProcessInfo.processInfo.systemUptime >= forceUntil {
            focusAnimationSpace = closedSpaces.first {
                activeSpaces.contains($0) && !heldSpaces.contains($0) && coordinator.sessions[$0] != nil
            }
        }

        // 7. Adopt native edge resizes on active representatives (on mouse up).
        let now = ProcessInfo.processInfo.systemUptime
        autoStackSettling = autoStackSettling.filter { $0.value > now }
        for space in activeSpaces where !heldSpaces.contains(space) {
            guard let session = coordinator.sessions[space],
                  let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { continue }
            for placement in placements {
                guard let exp = expected[placement.windowID], now - exp.at > 0.6,
                      let frame = byID[placement.windowID]?.frame, frame.isValid,
                      (abs(frame.width - exp.frame.width) > 2 || abs(frame.height - exp.frame.height) > 2), let pid = pidForWindow[placement.windowID] else { continue }
                if dragging == placement.windowID { endDrag() }
                if mouseDown { continue }
                if let until = autoStackSettling[placement.windowID], now < until {
                    // Not a user resize: put the even split back.
                    expected[placement.windowID] = (exp.frame, now)
                    applied.removeValue(forKey: space); forceApply = true
                    log("re-writing auto-stacked \(placement.windowID)")
                    continue
                }
                // Outer vertical edges belong to the tiled canvas. Restore them
                // even when no shared row divider can adopt the native resize.
                if abs(frame.height - exp.frame.height) > 2 { forceApply = true }
                if let resize = LiveReconciliation.rowResize(layout: session.state.layout,
                        slotID: placement.slotID, expected: exp.frame, actual: frame, gap: options.gap) {
                    if session.moveDivider(resize.divider, to: resize.position, gap: options.gap,
                                           ticket: session.ticket) {
                        applied.removeValue(forKey: space)
                        forceApply = true
                    }
                }
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
            for space in activeSpaces where !heldSpaces.contains(space) {
                guard let session = coordinator.sessions[space],
                      let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { continue }
                for placement in placements {
                    let wid = placement.windowID
                    guard let exp = expected[wid], now - exp.at > 0.6,
                          let frame = byID[wid]?.frame, frame.isValid, abs(frame.width - exp.frame.width) <= 2,
                          abs(frame.height - exp.frame.height) <= 2,
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
            if let space = focusAnimationSpace, let session = coordinator.sessions[space] {
                commandStarted = ProcessInfo.processInfo.systemUptime
                firstWriteMS = nil; finalWriteMS = nil; confirmedMS = nil
                // A timed-out owner may be missing from this survey. Use
                // current WindowServer geometry for known surviving windows.
                let placements = (try? session.state.layout.placements(in: session.canvas, gap: options.gap)) ?? []
                var animationSurvey = byID
                if placements.contains(where: { byID[$0.windowID] == nil }),
                   let cached = cachedStripSurveys(space: space, placements: placements,
                       source: latestSurvey) {
                    animationSurvey = cached
                }
                animateFocus(space: space, byID: animationSurvey)
            }
            // Keep the removal baseline until its animation actually finishes.
            // If an event interrupts it, the next pass must still animate.
            var completedSpaces = activeSpaces.subtracting(heldSpaces)
            if motionTimer != nil, let motionSpace { completedSpaces.remove(motionSpace) }
            pendingReflows.complete(spaces: completedSpaces)
            forceApply = false
            if let wid = raiseAfterApply, let element = raisable(wid) {
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
            autoStack(wid, newMembers: [wid], space: space)
        }
    }

    /// Records windows that appeared since the previous pass. Entries expire
    /// if the window has not been admitted within a few seconds (e.g. it
    /// stayed floating), so a later tile does not stack it.
    func noteNewWindows(_ ids: Set<UInt32>, now: Double) {
        if let known = knownWindows, !options.config.autoStack.isEmpty {
            for id in ids.subtracting(known) { newWindows[id] = now }
        }
        knownWindows = ids
        newWindows = newWindows.filter { ids.contains($0.key) && now - $0.value < 10 }
    }

    /// Stacks a just-admitted container below a lone window of an
    /// `autoStack` app on the same Space, at most two windows per column.
    func autoStack(_ wid: UInt32, newMembers: [UInt32], space: UInt64) {
        let fresh = newMembers.filter { newWindows.removeValue(forKey: $0) != nil }
        let config = options.config
        guard !fresh.isEmpty, !config.autoStack.isEmpty, let session = coordinator.sessions[space],
              let slotID = session.slots[wid] else { return }
        var bundles: [pid_t: String?] = [:]
        func listed(_ window: UInt32) -> Bool {
            guard let pid = pidForWindow[window] else { return false }
            if bundles[pid] == nil { bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
            return config.autoStacks(bundleID: bundles[pid] ?? nil)
        }
        guard listed(wid), let target = session.state.layout.autoStackTarget(for: slotID, stacks: { listed($0.activeMember) })
        else { return }
        let older = session.state.layout.columns.flatMap(\.slots).first { $0.id == target }?.activeMember
        if session.stackEvenly(windowID: wid, below: target, ticket: session.ticket) {
            let until = ProcessInfo.processInfo.systemUptime + 2
            for window in [wid] + (older.map { [$0] } ?? []) { autoStackSettling[window] = until }
            applied.removeValue(forKey: space)
            log("auto-stacked window \(wid) below \(target) on Space \(space)")
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
            minimizes.forget(wid)
            references.removeValue(forKey: wid); pidForWindow.removeValue(forKey: wid)
            expected.removeValue(forKey: wid); preferredWidth.removeValue(forKey: wid); frameConstraints.forget(wid)
            if journal.removeValue(forKey: wid) != nil { persistJournal() }
        }
        log("removed destroyed members \(gone.sorted())")
    }

    func reveal(_ session: ScopedLayoutSession) {
        var layout = session.state.layout
        if (try? layout.reveal(in: session.canvas, gap: options.gap,
                               autoCenter: options.config.autoCenter, autoCenterThreshold: options.config.autoCenterThreshold)) == true {
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
    /// Call site and uptime of the last interrupted animation (status only).
    var motionCancelledAt: String?
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
    /// A Space being switched to from the tray, until the deadline: the
    /// first refresh with it active animates any remaining placement.
    var spaceArrival: (space: UInt64, until: Double)?
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
    /// The directional slot `standaloneAction` came from, for its keystroke.
    var standaloneSlot: LiveConfig.SwipeSlot?
    var windowCloseTarget: (pid: pid_t, window: AXUIElement)?
    var standaloneClose = false
    var standalonePull = false
    var standaloneHintDirection = CGVector(dx: 0, dy: -1)

    var applied: [UInt64: [Placement]] = [:]

    /// A Space whose owner has not yet confirmed Paperi's minimize request.
    /// Its windows cannot be moved until the Dock effect ends; a write now
    /// would time out or land with the gap still open. Every window effect
    /// checks this here, at its entry point, rather than at each caller.
    func effectsHeld(_ space: UInt64) -> Bool {
        minimizes.pendingSpaces(now: ProcessInfo.processInfo.systemUptime).contains(space)
    }

    func apply(space: UInt64, byID: [UInt32: Survey]) {
        guard !effectsHeld(space) else { applied.removeValue(forKey: space); return }
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
            // An app that rounds its size (Terminal: whole text rows) keeps
            // the rounded frame; it is the baseline for resizes and moves.
            if let frame = row?.frame, frameConstraints.settledFrame(wid, for: target).map({ matches(frame, $0) }) == true
                || frameConstraints.settles(wid, at: frame, for: target) {
                if expected[wid]?.frame != frame { log("\(wid) keeps \(Int(frame.width))x\(Int(frame.height)) for \(Int(target.width))x\(Int(target.height))") }
                expected[wid] = (frame, ProcessInfo.processInfo.systemUptime); displaced.removeValue(forKey: wid); continue
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
