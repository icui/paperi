import AppKit
@preconcurrency import ApplicationServices
import PaperiBridge
import PaperiCore
import QuartzCore

/// Trackpad swipes, rendered with the snapshot overlay.
extension LiveManager {
    // MARK: swipe (snapshot renderer)

    /// One swipe: the strip's images follow `progress` towards at most one
    /// neighbour (−1 = left neighbour fully revealed, 1 = right). Nothing real
    /// moves and nothing logical changes until a committed release.
    struct Swipe {
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
        /// A downward pull that has turned left or right.
        var turned = false
        var turnDirection: Direction = .right
        /// The close-tab indicator replaces moving the window.
        var showsTabClose: Bool { closing && (pulling ? pullAction == .closeTab : tabCloseMode != nil) }
        /// Without a known native tab group, a downward close-tab action
        /// sends the app's own close-tab shortcut, ⌘W.
        var tabCloseMode: TabClose? { pulling ? tabClose ?? .app : tabClose }
        /// The new-window indicator replaces moving the window.
        var showsNewWindow: Bool { closing && pulling && (pullAction == .newWindow || pullAction == .openApp) }
        var showsIndicator: Bool { showsTabClose || showsNewWindow || (closing && pulling && pullAction == .minimize) }
        var indicatorStyle: GestureIndicatorStyle {
            var style: GestureIndicatorStyle = pullAction == .minimize && pulling ? .minimize : showsNewWindow ? .newWindow : .closeTab
            if pulling { style.direction = turned ? CGVector(dx: turnDirection == .left ? -1 : 1, dy: 0) : CGVector(dx: 0, dy: -1) }
            return style
        }
        /// When the indicator may first appear (media time). A fast flick
        /// releases before then and acts without flashing the indicator.
        var indicatorDue = 0.0
        var indicatorShown = false
        /// Set when a swipe up closes a tab rather than the window: the window
        /// stays put and a close-tab indicator tracks the fingers instead.
        let tabClose: TabClose?
        var starts: [UInt32: Rect] = [:]
        var progress = 0.0
        var targetProgress = 0.0
        var prediction = SlotSwipe.TrackingPrediction()
        var trackingFilter = SlotSwipe.TrackingFilter()
        var lastVisualTime = 0.0
        /// On-screen speed of the images, progress per second (smoothed).
        var visualVelocity = 0.0
        /// Speed of the finger target, progress per second (smoothed), and
        /// when its latest report was made (media time).
        var targetVelocity = 0.0
        var targetTime = 0.0
        /// Window-moving swipes share the trajectory renderer; action hints
        /// and downward pulls retain their existing tracking.
        var usesTrajectoryTracking: Bool { !closing || (!pulling && !showsIndicator) }
        var trackingMotion: SwipeTrajectory?
        var trackingBegan = 0.0
        var animatedReportTime = -Double.infinity

        mutating func sampleTracking(at time: Double) {
            guard let motion = trackingMotion else { return }
            let position = motion.position(at: time - trackingBegan)
            progress = closing ? max(0, position) : position
            visualVelocity = closing && position < 0 ? 0 : motion.velocity(at: time - trackingBegan)
        }
        /// The images are easing onto the fingers (the capture finished
        /// after the fingers had already moved) instead of jumping there.
        var catchingUp = false
        /// Tracking frame pacing, as the display clock delivered it.
        var lastFrameTime = 0.0
        var frames = 0
        var droppedFrames = 0
        var maxFrameMS = 0.0
        enum CaptureState { case pending, ready, failed }
        var captureState: CaptureState = .pending
        var ready: Bool { captureState == .ready }
        var failed: Bool { captureState == .failed }
        var tracking = true
        var released: Bool?
        var releaseDirection: Direction?
        /// The layout progress 0 stands for, and those of the neighbours at
        /// ∓1 (keyed like `ends`): what a release settles on.
        var base = Layout()
        var baseWindow: UInt32?
        var layouts: [Direction: Layout] = [:]
        /// A swipe that caught a landing in flight: `starts` are the frames
        /// the images were caught at, `origin` (progress) where that was,
        /// and `center` the frames at progress 0. Its release always writes
        /// the layout it settles on, even its own column.
        var caught = false
        var origin = 0.0
        var center: [UInt32: Rect]?
        /// A horizontal release sliding to its column; a new swipe may catch it.
        var landing: Landing?
    }
    /// A horizontal release on screen: progress `from` → `to` on `spring`.
    struct Landing {
        let began: Double
        let spring: SlotSwipe.Spring
        let from: Double
        let to: Double
        /// Where the images end up.
        let frames: [UInt32: Rect]
        func progress(at time: Double) -> Double {
            from + (to - from) * spring.fraction(at: time - began)
        }
    }
    enum TabClose: String {
        /// The window is the front tab of a native tab group (AX press).
        case native
        /// The app is listed in `gesture.tabCloseApps`; its tabs close with ⌘W.
        case app
    }
    /// Travel past the strip's ends, in points, at full progress.
    static let swipeEdgeResistance = 40.0
    /// Delay before the close-tab / new-window indicator appears after the lock.
    static let indicatorDelay = 0.12

    var motionActive: Bool { motionTimer != nil || swipe != nil }
    /// A focus scroll or a released swipe's landing/snap-back is on screen.
    /// Gesture input is ignored until it finishes; live finger tracking is not
    /// an animation.
    var gestureBlockedByAnimation: Bool { motionTimer != nil || swipe?.released != nil }
    /// A horizontal landing is on screen that a new swipe may take over.
    var landingCatchable: Bool {
        guard motionTimer == nil, let state = swipe, state.released != nil, !state.closing else { return false }
        return state.landing != nil && state.ready
    }

    func cancelSwipe() {
        windowIndicators.finishHorizontalSwipe()
        standaloneOverlay?.fadeOut(); standaloneOverlay = nil
        standalonePull = false
        standaloneClose = false
        swipeGuard?.invalidate(); swipeGuard = nil
        swipeSimulation?.invalidate(); swipeSimulation = nil
        swipeTask?.cancel(); swipeTask = nil
        // A gesture waiting for this animation outlives it.
        if gestureDeferred { resumeDeferredGestureSoon() } else { slotSwipe?.cancel(); slotSwipe = nil }
        guard let state = swipe else { return }
        state.overlay.hide()
        swipe = nil
        swipeMetrics["state"] = "cancelled"
    }

    static let fullScreenRefusal = "pointer is over a full-screen Space"

    /// The display under the pointer, as SkyLight reports it.
    func pointerDisplay() -> DisplaySpaceTopology? {
        let mouseLoc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }) else { return nil }
        let screenID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let uuid = CGDisplayCreateUUIDFromDisplayID(screenID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "Main"
        return coordinator.displays.first(where: { $0.displayUUID == uuid })
    }

    /// The display under the pointer is showing a Space without a strip
    /// (full-screen apps and other non-desktop Spaces).
    func pointerOverUnmanagedSpace() -> Bool {
        guard let display = pointerDisplay(), let space = display.activeSpaceID else { return false }
        return !display.userSpaces.contains(space)
    }

    func pointerContext() -> (session: ScopedLayoutSession, space: UInt64, pid: pid_t, window: UInt32)? {
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
        let tapConflicts = GestureConflict.checkLiveTap(fingers: options.config.gesture.fingers)
        source.recognizesTaps = options.config.gesture.tap != .none && tapConflicts.isEmpty
        if !tapConflicts.isEmpty, options.config.gesture.tap != .none {
            log("trackpad tap disabled due to conflicts: \(tapConflicts.joined(separator: ", "))")
        }
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
            + GestureConflict.checkLiveTap(fingers: options.config.gesture.fingers)
        if conflicts != lastGestureConflicts {
            lastGestureConflicts = conflicts
            updateTouchSource()
        }
    }


    func updateStandaloneHint(_ progress: Double, direction: Direction? = nil) {
        guard standalonePull || standaloneClose else { return }
        let config = options.config.gesture
        let action = direction.map { $0 == .left ? config.swipeDownLeft : config.swipeDownRight } ?? standaloneAction
        if standaloneOverlay == nil {
            let overlay = SnapshotTransition()
            overlay.prepareStandaloneIndicator()
            standaloneOverlay = overlay
        }
        if action != standaloneAction || direction != nil {
            standaloneOverlay?.replaceIndicator(duration: 0.14)
        }
        standaloneAction = action
        guard action != .none else { return }
        var style: GestureIndicatorStyle = (action == .newWindow || action == .openApp) ? .newWindow : action == .minimize ? .minimize : .closeTab
        style.direction = direction.map { CGVector(dx: $0 == .left ? -1 : 1, dy: 0) } ?? standaloneHintDirection
        standaloneHintDirection = style.direction
        standaloneOverlay?.trackIndicator(style, window: 0, progress: progress, threshold: config.commitThreshold)
    }


    func handleTouchEvent(_ event: TouchEvent) {
        guard running, !paused, DisplayArrangement.currentProblem() == nil else {
            dropDeferredGesture()
            cancelSwipe()
            slotSwipe?.cancel()
            slotSwipe = nil
            catchPending = false
            return
        }
        // A sequence that began during a landing leaves it alone until it
        // locks horizontally: resting fingers, taps and vertical swipes
        // must not stop a strip on its way to a column.
        let landingInFlight = swipe?.released != nil
        if catchPending {
            switch event {
            case .begin, .tap: catchPending = false
            case .cancel:
                catchPending = false; slotSwipe = nil; return
            case .end:
                // Lifted before an axis locked.
                guard landingInFlight else { catchPending = false; break }
                catchPending = false; slotSwipe = nil; return
            case .move: break
            }
        }
        switch event {
        case .begin(let time):
            dropDeferredGesture()
            let cfg = SlotSwipe.Configuration(
                travel: options.config.gesture.columnTravel,
                commitThreshold: options.config.gesture.commitThreshold,
                flickVelocity: options.config.gesture.flickVelocity,
                invert: options.config.gesture.invert,
                closeTravel: options.config.gesture.swipeUpToClose ? options.config.gesture.travel : nil,
                pullTravel: options.config.gesture.travel,
                turnTravel: options.config.gesture.travel,
                horizontalAcceleration: false
            )
            var swipeReducer = SlotSwipe(config: cfg)
            swipeReducer.begin(at: time)
            // A horizontal landing can be caught once the fingers lock. Any
            // other animation on screen (a focus scroll, a close, a hand-off)
            // is left to finish: the gesture is followed meanwhile and takes
            // effect when it has.
            let catching = landingCatchable
            if !catching && gestureBlockedByAnimation {
                slotSwipe = swipeReducer
                gestureDeferred = true
                return
            }
            standalonePull = false
            standaloneClose = false
            if !catching && focusedWindowIsManaged() {
                // Capture while determining the axis, but keep the overlay hidden
                // until horizontal movement locks. This overlaps input with capture.
                let started = beginSwipe(pendingLock: true)
                // Nothing to swipe on a full-screen Space; a retry on horizontal
                // lock would refuse again (and refresh again).
                if started["error"] as? String == Self.fullScreenRefusal {
                    slotSwipe = swipeReducer; return
                }
                applySwipeTravel(to: &swipeReducer)
            }
            slotSwipe = swipeReducer
            catchPending = catching

        case .move(let dx, let dy, let time):
            guard var swipeReducer = slotSwipe else { return }
            if gestureDeferred {
                if swipeReducer.move(dx: dx, dy: dy, at: time) == .cancelled { dropDeferredGesture(); return }
                slotSwipe = swipeReducer
                resumeDeferredGesture()
                return
            }
            if let action = swipeReducer.move(dx: dx, dy: dy, at: time) {
                if action == .cancelled {
                    catchPending = false
                    // The landing a vertical sequence began during goes on.
                    if swipe?.released == nil { cancelSwipe() }
                    slotSwipe = nil
                    return
                }
                if catchPending {
                    catchPending = false
                    // Locked while the landing is still on screen: a
                    // horizontal swipe takes it over; anything else waits
                    // for it. (If it has finished, this is an ordinary
                    // swipe from a strip at rest.)
                    if swipe?.released != nil {
                        guard action == .started, let offset = catchLanding() else {
                            slotSwipe = swipeReducer
                            gestureDeferred = true
                            return
                        }
                        swipeReducer.anchor(offset: offset)
                    }
                }
                switch action {
                case .started, .closeStarted, .pullStarted, .turnStarted:
                    guard enterSwipe(&swipeReducer, at: time) else { slotSwipe = nil; return }
                case .updated(let progress):
                    updateSwipe(progress, at: time)
                case .closeUpdated(let progress), .pullUpdated(let progress), .turnUpdated(let progress):
                    updateSwipe(progress, at: time)
                    updateStandaloneHint(progress)
                case .cancelled, .finished:
                    break
                }
            }
            slotSwipe = swipeReducer

        case .end(let time):
            guard var swipeReducer = slotSwipe else { return }
            let decision = swipeReducer.end(at: time)
            if gestureDeferred {
                // Released before the animation ahead of it finished: a
                // gesture that would have acted still does, once it has.
                guard decision != .snapBack else { dropDeferredGesture(); return }
                slotSwipe = swipeReducer
                deferredEnd = decision
                resumeDeferredGesture()
                return
            }
            slotSwipe = nil
            finishGesture(decision, turnDirection: swipeReducer.turnDirection)

        case .tap:
            guard options.config.gesture.tap == .tray else { return }
            log(showTray() ? "tap: tray at pointer" : "tap: no tray on this display")

        case .cancel:
            // Only a sequence we are tracking may cancel; an ignored one must
            // not tear down a running landing, nor may one that is waiting.
            guard slotSwipe != nil else { return }
            if gestureDeferred { dropDeferredGesture(); return }
            cancelSwipe()
            slotSwipe?.cancel()
            slotSwipe = nil
        }
    }

    /// Brings the overlay to where `reducer` is: on an axis lock, and when a
    /// gesture that waited for an animation takes effect (its reducer may
    /// already be past the lock, or released). False when the gesture cannot
    /// act and is to be dropped.
    func enterSwipe(_ reducer: inout SlotSwipe, at time: Double? = nil) -> Bool {
        enum Phase { case detecting, strip(Double), closing(Double), pulling(Double), turning(Double) }
        let phase: Phase
        switch reducer.state {
        case .detecting: phase = .detecting
        case .active(_, let progress, _, _): phase = .strip(progress)
        case .closing(_, let progress, _, _): phase = .closing(progress)
        case .pulling(_, let progress, _, _): phase = .pulling(progress)
        case .turning(_, let progress, _, _): phase = .turning(progress)
        case .completed(.commit): phase = .strip(0)
        case .completed(.close): phase = .closing(0)
        case .completed(.pull): phase = .pulling(0)
        case .completed(.turn): phase = .turning(0)
        case .completed(.snapBack), .idle, .cancelled: return false
        }
        func begun(pendingLock: Bool = false) -> Bool {
            swipe != nil || beginSwipe(pendingLock: pendingLock)["ok"] as? Bool == true
        }
        /// A pull without a strip to act on still acts on the frontmost app.
        func enterPull() {
            guard !standalonePull, swipe?.pulling != true else { return }
            if !focusedWindowIsManaged() {
                cancelSwipe()
                standalonePull = true
            } else if !begun() {
                standalonePull = true
            } else if !startClosing(pull: true) {
                cancelSwipe()
                standalonePull = true
            }
            if standalonePull {
                standaloneAction = options.config.gesture.swipeDown
                standaloneHintDirection = CGVector(dx: 0, dy: -1)
            }
        }
        switch phase {
        case .detecting:
            if swipe == nil, beginSwipe(pendingLock: true)["error"] as? String == Self.fullScreenRefusal { return false }
            applySwipeTravel(to: &reducer)
        case .strip:
            guard begun() else { reducer.cancel(); return false }
            applySwipeTravel(to: &reducer)
            if case .active(_, let progress, _, _) = reducer.state { updateSwipe(progress, at: time) }
        case .closing(let progress):
            if standaloneClose || !focusedWindowIsManaged() {
                if !standaloneClose {
                    cancelSwipe()
                    standaloneClose = true
                    standaloneAction = .closeTab
                    standaloneHintDirection = CGVector(dx: 0, dy: 1)
                }
                updateStandaloneHint(progress)
            } else {
                guard begun(), startClosing() else { cancelSwipe(); return false }
                updateSwipe(progress, at: time)
            }
        case .pulling(let progress):
            enterPull()
            updateStandaloneHint(progress)
            updateSwipe(progress, at: time)
        case .turning(let progress):
            enterPull()
            guard standalonePull || startTurn(direction: reducer.turnDirection) else { cancelSwipe(); return false }
            updateStandaloneHint(progress, direction: reducer.turnDirection)
            updateSwipe(progress, at: time)
        }
        return true
    }

    /// Acts on a released gesture.
    func finishGesture(_ decision: SlotSwipe.Decision, turnDirection: Direction) {
        if standaloneClose {
            standaloneOverlay?.fadeOut(); standaloneOverlay = nil
            standaloneClose = false
            if decision == .close { performStandalonePull(.closeTab) }
            return
        }
        if standalonePull {
            standaloneOverlay?.fadeOut(); standaloneOverlay = nil
            standalonePull = false
            if decision == .pull || decision == .turn {
                let cfg = options.config.gesture
                let action = decision == .pull ? cfg.swipeDown : (turnDirection == .left ? cfg.swipeDownLeft : cfg.swipeDownRight)
                performStandalonePull(action)
            }
            return
        }
        switch decision {
        case .commit(let direction):
            endSwipe(commit: true, direction: direction)
        case .close, .pull, .turn:
            endSwipe(commit: true)
        case .snapBack:
            endSwipe(commit: false)
        }
    }

    // MARK: gestures made during an animation

    func dropDeferredGesture() {
        guard gestureDeferred else { return }
        gestureDeferred = false
        deferredEnd = nil
        slotSwipe = nil
    }

    /// An animation ended; a waiting gesture may take effect. Asynchronous:
    /// callers are still tearing that animation down.
    func resumeDeferredGestureSoon() {
        windowIndicators.finishHorizontalSwipe()
        guard gestureDeferred else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.resumeDeferredGesture() }
        }
    }

    /// Starts the waiting gesture where its fingers are now, if nothing is
    /// animating any more. A gesture already released acts at once.
    func resumeDeferredGesture() {
        guard gestureDeferred, !resumingGesture else { return }
        guard var reducer = slotSwipe, running, !paused else { dropDeferredGesture(); return }
        guard !gestureBlockedByAnimation else { return }
        resumingGesture = true
        defer { resumingGesture = false }
        standalonePull = false
        // The finished animation may have changed the strip (a closed
        // window is still in the layout until a refresh): reconcile, then
        // try again. That refresh may itself animate; then keep waiting.
        if swipe == nil, let error = beginSwipe(pendingLock: true)["error"] as? String, error != Self.fullScreenRefusal {
            refresh()
            guard gestureDeferred, !gestureBlockedByAnimation else { return }
        }
        let end = deferredEnd
        gestureDeferred = false
        deferredEnd = nil
        guard enterSwipe(&reducer) else { slotSwipe = nil; return }
        if let end {
            slotSwipe = nil
            finishGesture(end, turnDirection: reducer.turnDirection)
        } else {
            slotSwipe = reducer
        }
    }

    /// Shows the thumbnail tray of the display under the pointer, centred on
    /// the pointer. Returns false when that display has no tray to show.
    @discardableResult func showTray() -> Bool {
        guard let display = pointerDisplay() else { return false }
        return windowIndicators.summon(display: display.displayUUID, at: NSEvent.mouseLocation, coordinator: coordinator)
    }

    /// Accessory apps can own keyboard focus without owning the menu bar.
    /// Resolve the focused element's process before falling back to the active app.
    func gestureFocus() -> (pid: pid_t, window: AXUIElement?)? {
        if NSApp.keyWindow != nil {
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute)
            let window = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            return (ProcessInfo.processInfo.processIdentifier, window)
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var pid: pid_t = 0
        if let value = Diagnostics.attribute(system, kAXFocusedUIElementAttribute),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            _ = AXUIElementGetPid((value as! AXUIElement), &pid)
        }
        if pid <= 0 { pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        guard pid > 0 else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute)
        let window = value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        return (pid, window)
    }

    /// Consult keyboard focus rather than the strip's last focus or menu bar.
    func focusedWindowIsManaged() -> Bool {
        guard let window = gestureFocus()?.window else { return false }
        let wid = paperi_window_id(window)
        guard let space = coordinator.spaceForWindow[wid],
              let session = coordinator.sessions[space] else { return false }
        return session.state.layout.columns.contains { column in
            column.slots.contains { $0.members.contains(wid) }
        }
    }

    /// App actions remain available when no tiled window can supply a strip.
    func performStandalonePull(_ action: LiveConfig.SwipeDownAction) {
        if action == .openApp { _ = openConfiguredApp(); return }
        guard let focus = gestureFocus() else { return }
        let pid = focus.pid
        let window = focus.window
        // Our settings window belongs to an accessory app. Handle it directly:
        // a process-targeted shortcut need not reach its key window.
        if pid == ProcessInfo.processInfo.processIdentifier, let keyWindow = NSApp.keyWindow {
            if action == .closeTab { keyWindow.performClose(nil); scheduleRefresh(); return }
            if action == .minimize { keyWindow.performMiniaturize(nil); scheduleRefresh(); return }
        }
        switch action {
        case .none, .openApp: break
        case .minimize:
            if let window { _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        case .newWindow:
            if let item = Self.newWindowMenuItem(pid: pid),
               AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return }
            Self.postAppCommand(Self.keyN, pid: pid)
        case .closeTab:
            if NSRunningApplication(processIdentifier: pid)?.activationPolicy == .accessory,
               let window,
               let value = Diagnostics.attribute(window, kAXCloseButtonAttribute),
               CFGetTypeID(value) == AXUIElementGetTypeID(),
               AXUIElementPerformAction((value as! AXUIElement), kAXPressAction as CFString) == .success {
                break
            }
            Self.postAppCommand(Self.keyW, pid: pid)
            focusManagedWindowAfterCommandW()
        }
        scheduleRefresh()
    }

    /// Give the app time to close or show a save prompt before restoring focus.
    func focusManagedWindowAfterCommandW() {
        guard let space = pointerDisplay()?.activeSpaceID else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.running, !self.paused,
                  NSEvent.pressedMouseButtons == 0, !self.motionActive,
                  DisplayArrangement.currentProblem() == nil,
                  self.coordinator.display(forSpace: space)?.activeSpaceID == space,
                  let app = NSWorkspace.shared.frontmostApplication else { return }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            // Another tab/window or an unsaved-changes prompt keeps its focus.
            var focused: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
            guard result == .noValue || (result == .success && focused == nil) else { return }
            guard let session = self.coordinator.sessions[space],
                  !session.state.interactionSuppressed,
                  let slot = session.state.layout.focused,
                  let index = session.state.layout.index(of: slot) else { return }
            let wid = session.state.layout.columns[index.column].slots[index.row].activeMember
            guard Self.windowOnScreen(wid) else { return }
            _ = self.raise(wid)
        }
    }

    /// Always opens a new window of the configured app. Launching an app
    /// creates its initial window. A running app is never reopened through
    /// `NSWorkspace`: that sends a reopen event, which apps answer by
    /// restoring a minimized window instead. It is activated directly and
    /// asked for a new window (menu item, else ⌘N once it is frontmost).
    @discardableResult func openConfiguredApp() -> Bool {
        guard let bundleID = options.config.gesture.swipeDownApp else { return false }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) {
            let pid = app.processIdentifier
            let pressed = Self.newWindowMenuItem(pid: pid)
                .map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
            app.activate(options: [])
            if !pressed {
                Task { @MainActor in
                    // ⌘N needs keyboard focus; wait briefly for activation.
                    for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    Self.postAppCommand(Self.keyN, pid: pid)
                }
            }
            return true
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        return true
    }

    static func postAppCommand(_ key: CGKeyCode, pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            event.flags = .maskCommand
            event.postToPid(pid)
        }
    }

    /// Captures the strip of the focused window's Space and shows it frozen
    /// in place. Updates and a release may arrive before the capture finishes.
    @discardableResult func beginSwipe(isSimulation: Bool = false, pendingLock: Bool = false) -> [String: Any] {
        defer { if running { windowIndicators.update(coordinator, mode: options.config.bottomDotsVisibility) } }
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
        guard let destinations = swipeDestinations(from: session.state.layout, session: session, surveys: surveys) else {
            scheduleRefresh(); return fail("strip not settled")
        }
        let ends = destinations.ends, neighbours = destinations.neighbours
        let generation = motionGeneration
        let overlay = SnapshotTransition(snapshotStyle: options.config.gesture.snapshotStyle)
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
        swipe?.base = session.state.layout
        swipe?.baseWindow = ctx.window
        swipe?.layouts = destinations.layouts
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
        let starts = surveys.compactMapValues(\.frame)
        var captureIDs = LiveReconciliation.swipeCaptureIDs(starts: starts, destinations: Array(ends.values), canvas: canvas)
        if let closeWindow { captureIDs.insert(closeWindow) }
        let snapshotIDs = captureIDs
        swipeTask = Task { [weak self] in
            do {
                try await overlay.prepare(windows: snapshotIDs, excluding: Set(surveys.keys), canvas: canvas)
                guard let self, var state = self.swipe, state.generation == generation else { overlay.hide(); return }
                guard self.running, AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0,
                      self.coordinator.display(forSpace: space)?.activeSpaceID == space else {
                    self.cancelMotion(); self.scheduleRefresh(); return
                }
                state.starts = starts.merging(overlay.captured) { _, captured in captured }
                state.captureState = .ready
                self.swipe = state
                self.swipeMetrics = ["state": "tracking", "windows": surveys.count, "captureMS": overlay.captureMS,
                                     "textureBytes": overlay.textureBytes, "capturedWindows": snapshotIDs.count, "snapshotStyle": overlay.snapshotStyle.rawValue]
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
                state.captureState = .failed
                self.swipe = state
                self.swipeMetrics = ["state": "fallback", "reason": String(describing: error)]
                if let commit = state.released { state.released = nil; self.swipe = state; self.endSwipe(commit: commit, direction: state.releaseDirection) }
            }
        }
        return ["ok": true, "neighbours": neighbours.count]
    }

    /// Where a swipe from `base` lands either way: for each direction the
    /// nearest column that needs scrolling to reveal (if every column that way
    /// is already fully visible, the adjacent one), as frames, its window and
    /// its layout. Nil when a target size differs from the window's, as
    /// images keep their size and cannot show that by sliding.
    func swipeDestinations(from base: Layout, session: ScopedLayoutSession, surveys: [UInt32: Survey])
        -> (ends: [Direction: [UInt32: Rect]], neighbours: [Direction: UInt32], layouts: [Direction: Layout])? {
        var ends: [Direction: [UInt32: Rect]] = [:], neighbours: [Direction: UInt32] = [:], layouts: [Direction: Layout] = [:]
        for direction in [Direction.left, .right] {
            var candidate = base
            var firstStep: Layout?
            var scrolled = false
            while let id = candidate.neighbor(direction) {
                candidate.focused = id
                if firstStep == nil { firstStep = candidate }
                if (try? candidate.reveal(in: session.canvas, gap: options.gap,
                               autoCenter: options.config.autoCenter, autoCenterThreshold: options.config.autoCenterThreshold)) == true { scrolled = true; break }
            }
            guard var layout = scrolled ? candidate : firstStep else { continue }
            _ = try? layout.reveal(in: session.canvas, gap: options.gap,
                               autoCenter: options.config.autoCenter, autoCenterThreshold: options.config.autoCenterThreshold)
            guard let id = layout.focused, let loc = layout.index(of: id) else { continue }
            guard let placements = try? layout.placements(in: session.canvas, gap: options.gap) else { continue }
            let targets = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
            guard surveys.allSatisfy({ wid, row in
                guard let frame = row.frame, let target = targets[wid] else { return false }
                return LiveReconciliation.animationSizeMatches(frame, target)
            }) else { return nil }
            ends[direction] = targets
            neighbours[direction] = layout.columns[loc.column].slots[loc.row].activeMember
            layouts[direction] = layout
        }
        return (ends, neighbours, layouts)
    }

    /// The window in `layout`'s focused slot.
    static func focusedWindow(_ layout: Layout) -> UInt32? {
        guard let id = layout.focused, let loc = layout.index(of: id) else { return nil }
        return layout.columns[loc.column].slots[loc.row].activeMember
    }

    /// A new swipe takes over the horizontal landing on screen, as on a
    /// phone's home screen: the images stop where they are, and the swipe
    /// continues from the column nearest to there. Nothing real moves until
    /// its release. Returns where the strip was caught, in progress from that
    /// column; nil (the landing goes on) when it cannot be taken over.
    func catchLanding() -> Double? {
        guard landingCatchable, let old = swipe, let landing = old.landing,
              running, NSEvent.pressedMouseButtons == 0, drag == nil,
              DisplayArrangement.currentProblem() == nil,
              coordinator.display(forSpace: old.space)?.activeSpaceID == old.space,
              let session = coordinator.sessions[old.space], !session.state.interactionSuppressed,
              // Windows came or went since the strip was captured: no images for that.
              session.state.layout.columns == old.base.columns else { return nil }
        let now = CACurrentMediaTime()
        let caughtAt = landing.progress(at: now)
        var columns: [Int: Layout] = [0: old.base]
        if let layout = old.layouts[.left] { columns[-1] = layout }
        if let layout = old.layouts[.right] { columns[1] = layout }
        let slot = SlotSwipe.nearestSlot(caughtAt, available: Set(columns.keys))
        guard let base = columns[slot], let baseWindow = Self.focusedWindow(base),
              let placements = try? base.placements(in: session.canvas, gap: options.gap),
              let destinations = swipeDestinations(from: base, session: session, surveys: old.surveys) else { return nil }
        let center = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
        guard old.surveys.keys.allSatisfy({ center[$0] != nil }) else { return nil }
        // Catch the images exactly where they are on screen; the rest of
        // the strip (no image) where the path has it.
        let shown = old.overlay.freeze()
        let starts = swipeFrames(old, progress: caughtAt).merging(shown) { _, frame in frame }
        swipeTask?.cancel(); swipeTask = nil
        motionGeneration &+= 1
        var next = Swipe(space: old.space, generation: motionGeneration, overlay: old.overlay, surveys: old.surveys,
                         ends: destinations.ends, neighbours: destinations.neighbours, canvas: session.canvas,
                         closeWindow: nil, tabClose: nil)
        next.base = base
        next.baseWindow = baseWindow
        next.layouts = destinations.layouts
        next.caught = true
        next.origin = caughtAt - Double(slot)
        next.center = center
        next.starts = starts
        next.progress = next.origin
        next.targetProgress = next.origin
        next.prediction = .init(target: next.origin)
        next.lastVisualTime = now
        next.captureState = .ready
        swipe = next
        swipeBegan = ProcessInfo.processInfo.systemUptime
        swipeMetrics = ["state": "caught", "caughtAt": caughtAt, "column": slot, "windows": old.surveys.count]
        old.overlay.startFrameClock { [weak self] link in self?.advanceSwipeVisuals(link) }
        captureReachable(from: base, ends: destinations.ends, state: next)
        return next.origin
    }

    /// Adds images, in the background, for strip windows a swipe from
    /// `layout` could bring on screen but the overlay has none of (a caught
    /// swipe reaches further along the strip than the first capture).
    func captureReachable(from layout: Layout, ends: [Direction: [UInt32: Rect]], state: Swipe) {
        guard let session = coordinator.sessions[state.space],
              let placements = try? layout.placements(in: session.canvas, gap: options.gap) else { return }
        let center = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
        let ids = LiveReconciliation.swipeCaptureIDs(starts: center, destinations: Array(ends.values), canvas: session.canvas)
            .intersection(state.surveys.keys)
        let overlay = state.overlay
        guard !ids.subtracting(overlay.captured.keys).isEmpty else { return }
        Task { [weak self] in
            await overlay.capture(more: ids, at: { wid in
                // Where the image belongs now: on the tracking path, or where
                // a landing ends (such windows are off screen until then).
                guard let self, let state = self.swipe, state.overlay === overlay else { return nil }
                if state.released == nil { return self.swipeFrames(state)[wid] }
                return state.landing?.frames[wid] ?? state.starts[wid]
            })
        }
    }

    /// Switches a tracking swipe to closing its focused window, or to the
    /// configured downward action.
    func startClosing(pull: Bool = false) -> Bool {
        guard var state = swipe, state.released == nil, state.closeWindow != nil else { return false }

        state.closing = true
        state.pulling = pull
        state.pullAction = options.config.gesture.swipeDown
        swipe = state
        // Nothing moves: show only the indicator over the live windows.
        if state.showsIndicator {
            state.indicatorDue = CACurrentMediaTime() + Self.indicatorDelay
            swipe = state
            state.overlay.showIndicatorOnly()
        }
        return true
    }

    /// Switches a pull to the configured left or right action, with a fresh
    /// indicator following the fingers from rest.
    func startTurn(direction: Direction) -> Bool {
        guard var state = swipe, state.released == nil, state.pulling else { return false }
        state.turned = true
        state.turnDirection = direction
        state.pullAction = direction == .left ? options.config.gesture.swipeDownLeft : options.config.gesture.swipeDownRight
        state.progress = 0
        state.targetProgress = 0
        state.prediction = .init()
        state.trackingFilter = .init()
        state.visualVelocity = 0
        state.targetVelocity = 0
        state.targetTime = 0
        state.indicatorShown = false
        // Already past the delay; a turn released at once has no indicator to flash.
        state.indicatorDue = min(state.indicatorDue, CACurrentMediaTime())
        swipe = state
        state.overlay.replaceIndicator(duration: 0.14)
        swipeMetrics["turned"] = true
        return true
    }

    /// Keep only the newest finger target and how fast it is moving.
    /// `time`: when the fingers were there (event time); now if omitted.
    func updateSwipe(_ progress: Double, at time: Double? = nil) {
        guard var state = swipe, state.released == nil, progress.isFinite else { return }
        let wasTracking = state.tracking
        state.tracking = true
        let now = CACurrentMediaTime()
        // Event and media time share a clock; distrust one that disagrees.
        let at = time.flatMap { abs($0 - now) < 0.5 ? $0 : nil } ?? now
        let target = state.closing ? min(1.3, max(0, progress)) : min(1.3, max(-1.3, progress))
        if wasTracking, state.targetTime > 0, at > state.targetTime {
            let dt = at - state.targetTime
            let instant = (target - state.targetProgress) / max(1.0 / 240, dt)
            state.targetVelocity += (1 - exp(-dt / 0.025)) * (instant - state.targetVelocity)
        } else if !wasTracking || state.targetTime == 0 {
            state.targetVelocity = 0
        }
        state.prediction.observe(target)
        state.targetProgress = target
        state.targetTime = max(state.targetTime, at)
        if !wasTracking {
            // Time the first tracked frame from now, not from when the
            // capture finished, and ease onto wherever the fingers are.
            state.lastVisualTime = now
            state.catchingUp = true
        }
        swipe = state
        if !state.closing, let display = coordinator.displays.first(where: { $0.activeSpaceID == state.space }) {
            windowIndicators.beginHorizontalSwipe(display: display.displayUUID, coordinator: coordinator,
                                                   mode: options.config.bottomDotsVisibility)
        }
        if state.ready && !wasTracking { state.overlay.show() }
    }

    /// Display ticks submit horizontal/swipe-up window trajectories.
    /// Action indicators and downward pulls keep their existing placement.
    func advanceSwipeVisuals(_ link: CADisplayLink) {
        guard var state = swipe, state.ready, state.tracking, state.released == nil else { return }
        let period = link.targetTimestamp - link.timestamp
        if state.lastFrameTime > 0, period > 0 {
            let interval = link.timestamp - state.lastFrameTime
            state.frames += 1
            state.maxFrameMS = max(state.maxFrameMS, interval * 1000)
            state.droppedFrames += max(0, Int((interval / period).rounded()) - 1)
        }
        state.lastFrameTime = link.timestamp
        if state.usesTrajectoryTracking {
            advanceSnapshotTracking(&state)
            swipe = state
            return
        }
        let now = link.targetTimestamp
        let elapsed = min(1.0 / 30, max(0, now - state.lastVisualTime))
        let age = max(0, now - state.targetTime)
        var aim = state.prediction.position(from: state.progress, velocity: state.targetVelocity, age: age, period: period)
        aim = state.closing ? min(1.3, max(0, aim)) : min(1.3, max(-1.3, aim))
        var next = state.trackingFilter.advance(from: state.progress, toward: aim, elapsed: elapsed)
        if state.catchingUp {
            next = state.progress + (next - state.progress) * (1 - exp(-elapsed / 0.03))
            if abs(aim - next) < 0.004 { state.catchingUp = false }
        }
        if elapsed > 0 {
            let instant = (next - state.progress) / elapsed
            state.visualVelocity += (1 - exp(-elapsed / 0.03)) * (instant - state.visualVelocity)
        }
        state.lastVisualTime = now
        let changed = next != state.progress
        state.progress = next
        if state.showsIndicator {
            // Held still past the delay: show the indicator without waiting for movement.
            guard now >= state.indicatorDue, changed || !state.indicatorShown, let wid = state.closeWindow else {
                swipe = state; return
            }
            state.indicatorShown = true
            swipe = state
            state.overlay.trackIndicator(state.indicatorStyle, window: wid, progress: next,
                                         threshold: options.config.gesture.commitThreshold)
            return
        }
        swipe = state
        guard changed else { return }
        state.overlay.place(swipeFrames(state))
        if state.closing, let wid = state.closeWindow { state.overlay.setOpacity(wid, closeOpacity(next)) }
    }

    /// Submit only when a touch report changes. Core Animation continues the
    /// bounded trajectory between reports, even when the main thread is busy.
    func advanceSnapshotTracking(_ state: inout Swipe) {
        let now = CACurrentMediaTime()
        state.sampleTracking(at: now)
        guard state.animatedReportTime != state.targetTime else { return }
        let age = max(0, now - state.targetTime)
        let velocity = state.targetVelocity * max(0, 1 - age / 0.06)
        // Forecast at most 25 ms ahead; never integrate speed indefinitely.
        let target = state.prediction.position(from: state.progress, velocity: velocity,
                                               age: min(age + 0.025, 0.06), period: 1.0 / 60)
        let motion = SwipeTrajectory(start: state.progress, target: min(1.3, max(state.closing ? 0 : -1.3, target)),
                                     velocity: state.visualVelocity)
        let path = state
        state.overlay.track(along: { self.swipeFrames(path, progress: path.closing ? max(0, $0) : $0) },
                            motion: motion, began: now, fadingWindow: state.closing ? state.closeWindow : nil,
                            opacity: { self.closeOpacity($0) })
        state.trackingMotion = motion
        state.trackingBegan = now
        state.animatedReportTime = state.targetTime
        swipeMetrics["trackingRenderer"] = "coreAnimationPrediction"
        swipeMetrics["trackingTrajectoryMS"] = motion.duration * 1000
    }

    /// Finger travel (fraction of the trackpad width) for a full step each
    /// way: proportional to how far the strip scrolls, so the strip moves
    /// the same distance per unit of finger travel whatever the column
    /// widths. `gesture.columnTravel` scrolls one canvas width. Nil for a
    /// side without a neighbour.
    func swipeTravel(_ state: Swipe) -> (left: Double?, right: Double?) {
        let from = state.center ?? (state.starts.isEmpty ? state.surveys.compactMapValues(\.frame) : state.starts)
        let unit = options.config.gesture.columnTravel
        func travel(_ side: Direction) -> Double? {
            guard let ends = state.ends[side], state.canvas.width > 0 else { return nil }
            let distance = from.compactMap { id, start in ends[id].map { abs($0.x - start.x) } }.max() ?? 0
            // A neighbour already (nearly) in view still takes a deliberate move.
            return min(2 * unit, max(min(0.1, unit), unit * distance / state.canvas.width))
        }
        return (travel(.left), travel(.right))
    }

    /// Gives `reducer` the current swipe's travel each way.
    func applySwipeTravel(to reducer: inout SlotSwipe) {
        guard let state = swipe, !state.closing else { return }
        let travel = swipeTravel(state)
        reducer.retarget(travelLeft: travel.left, travelRight: travel.right)
    }

    func swipeFrames(_ state: Swipe) -> [UInt32: Rect] { swipeFrames(state, progress: state.progress) }

    func swipeFrames(_ state: Swipe, progress: Double) -> [UInt32: Rect] {
        // Closing a tab leaves the window where it is.
        if state.closing { return state.showsIndicator ? state.starts : closeFrames(state, progress: progress) }
        let center = state.center ?? state.starts
        // From `from` towards the neighbour on `side`, `travelled` progress
        // since `from`; past the neighbour (or at a strip end) resist,
        // moving at most a few points.
        func towards(_ side: Direction, from: [UInt32: Rect], fraction: Double, travelled: Double) -> [UInt32: Rect] {
            guard let ends = state.ends[side] else {
                let shift = -Self.swipeEdgeResistance * travelled
                return from.mapValues { var frame = $0; frame.x += shift; return frame }
            }
            let frames = LiveReconciliation.interpolate(from, ends, progress: min(1, fraction), canvas: state.canvas)
            let excess = max(0, abs(progress) - 1)
            guard excess > 0 else { return frames }
            let extraShift = (side == .left ? 1.0 : -1.0) * excess * Self.swipeEdgeResistance
            return frames.mapValues { var frame = $0; frame.x += extraShift; return frame }
        }
        switch SlotSwipe.leg(progress, offset: state.origin) {
        case .toColumn(let fraction):
            return LiveReconciliation.interpolate(state.starts, center, progress: fraction, canvas: state.canvas)
        case .fromColumn(let side, let fraction):
            return towards(side, from: center, fraction: fraction, travelled: progress)
        case .fromCaught(let side, let fraction):
            return towards(side, from: state.starts, fraction: fraction, travelled: progress - state.origin)
        }
    }

    /// Swipe up (down): only the window being closed (minimized) moves,
    /// straight up (down). At 1 it and its shadow are just past that edge of
    /// its display; going down, it passes under the Dock.
    func closeFrames(_ state: Swipe, progress: Double) -> [UInt32: Rect] {
        guard let wid = state.closeWindow, var frame = state.starts[wid] else { return state.starts }
        let distance = state.pulling
            ? state.overlay.screenBottom - frame.y + state.overlay.closeShadowClearance
            : frame.y + frame.height - state.overlay.screenTop + state.overlay.closeShadowClearance
        let absP = min(1, progress)
        frame.y -= (state.pulling ? -1 : 1) * (distance * absP + max(0, progress - 1) * Self.swipeEdgeResistance)
        var frames = state.starts
        frames[wid] = frame
        return frames
    }

    /// A closing window stays opaque until release would close it (the
    /// commit threshold), then fades slightly as it rises: 70% once fully off.
    func closeOpacity(_ progress: Double) -> Double {
        let threshold = min(0.99, options.config.gesture.commitThreshold)
        return 1 - 0.3 * min(1, max(0, (progress - threshold) / (1 - threshold)))
    }

    enum CloseMethod: String { case press, key, none }

    /// Every native tab in the window's slot, itself included.
    func tabGroup(_ wid: UInt32) -> Set<UInt32> {
        guard let space = coordinator.spaceForWindow[wid], let session = coordinator.sessions[space],
              let slot = session.state.layout.columns.lazy.flatMap(\.slots).first(where: { $0.members.contains(wid) })
        else { return [wid] }
        return Set(slot.members)
    }

    /// Presses the window's close button through Accessibility; in a native
    /// tab group that closes only the front tab. Without a usable close
    /// button (custom window controls), ⌘W goes to the app, but only while
    /// this window is its focused window, so it cannot close a different one.
    func pressClose(_ wid: UInt32) -> CloseMethod {
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

    static func sendCommandW(to pid: pid_t, window wid: UInt32) -> Bool { sendCommand(keyW, to: pid, window: wid) }

    /// ⌘`key` to the app, only while `wid` is its focused window.
    static func sendCommand(_ key: CGKeyCode, to pid: pid_t, window wid: UInt32) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        guard let value = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID(),
              // Parentheses silence Swift’s optional-argument cast warning after the CF type check.
              paperi_window_id((value as! AXUIElement)) == wid else { return false }
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
    static func windowOnScreen(_ wid: UInt32) -> Bool {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]] ?? []
        return rows.contains { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
    }

    /// Committed swipe up: the image leaves through the top while the app
    /// closes the window underneath. The overlay goes once the window has
    /// gone, so the survivors' gap animation plays on the real windows. A
    /// window that stays (an unsaved-changes prompt) is revealed by fading
    /// the overlay, without bringing its old snapshot back on screen.
    func finishClose(_ state: Swipe, settle: Double) {
        guard let wid = state.closeWindow else { return }
        if state.pulling && state.pullAction == .none { cancelSwipe(); return }
        if state.showsTabClose, let mode = state.tabCloseMode { finishTabClose(state, window: wid, mode: mode); return }
        if state.showsNewWindow { finishNewWindow(state, window: wid); return }
        if state.pulling { finishMinimize(state, window: wid, settle: settle); return }
        let generation = state.generation, overlay = state.overlay
        let from = state.progress, path = state
        // Leave at the speed the window had on screen, then slow to the edge.
        let distance = max(0, 1 - from)
        let spring = SlotSwipe.Spring(distance: distance, speed: state.visualVelocity, response: settle)
        let duration = spring.duration
        overlay.slide(along: { u in self.closeFrames(path, progress: from + (1 - from) * u) },
                      to: closeFrames(path, progress: 1), spring: spring)
        overlay.fade(wid, to: closeOpacity(1), duration: duration)
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
            // A timeout is not a refusal: the app may still be closing, or
            // WindowServer may still report its closing animation. Returning
            // the snapshot here can resurrect a successfully closed window.
            // Reveal any surviving window or save prompt under the overlay.
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil; self.resumeDeferredGestureSoon()
            self.swipeMetrics["state"] = gone ? "closed" : (pressed ? "closeRefused" : "noCloseButton")
            self.swipeMetrics["closeMS"] = (ProcessInfo.processInfo.systemUptime - released) * 1000
            self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
            self.scheduleRefresh()
        }
    }

    /// Minimizes through Accessibility. False when the window refuses.
    func minimize(_ wid: UInt32) -> Bool {
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
    func finishMinimize(_ state: Swipe, window wid: UInt32, settle: Double) {
        let generation = state.generation, overlay = state.overlay
        let from = state.progress, path = state
        let distance = max(0, 1 - from)
        let spring = SlotSwipe.Spring(distance: distance, speed: state.visualVelocity, response: settle)
        let duration = spring.duration
        overlay.slide(along: { u in self.closeFrames(path, progress: from + (1 - from) * u) },
                      to: closeFrames(path, progress: 1), spring: spring)
        overlay.fade(wid, to: closeOpacity(1), duration: duration)
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
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil; self.resumeDeferredGestureSoon()
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
    func collapseGap(after wid: UInt32, state: Swipe) -> (targets: [UInt32: Rect], duration: Double)? {
        guard let session = coordinator.sessions[state.space], isActiveRepresentative(wid) else { return nil }
        let members = Set(session.members(of: wid) ?? [wid])
        let previousLayout = session.state.layout
        let target = neighbourAfterClose(members)
        guard (try? coordinator.removeContainer(containing: wid, classification: Self.tiled)) != nil else { return nil }
        if let target {
            try? session.focus(windowID: target, ownerPID: pidForWindow[target], classification: Self.tiled, ticket: session.ticket)
            closeFocus = (target, ProcessInfo.processInfo.systemUptime + 0.8)
            log("focus after minimize: \(target)")
        }
        if let offset = LiveReconciliation.offsetAfterTrailingClose(previous: previousLayout,
                current: session.state.layout, canvas: session.canvas, gap: options.gap) {
            session.setOffset(offset, ticket: session.ticket)
        }
        reveal(session)
        applied.removeValue(forKey: state.space)
        let duration = options.config.focusScrollDuration ?? 0.22
        guard duration > 0, let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { return nil }
        let targets = LiveReconciliation.focusTargets(placements, canvas: session.canvas, screenInset: options.outerGap)
        // Every survivor needs an image of the right size to slide.
        guard targets.allSatisfy({ id, frame in
            guard let start = state.starts[id] else { return false }
            return LiveReconciliation.animationSizeMatches(start, frame)
        }) else { return nil }
        state.overlay.slide(to: targets, duration: duration, easeIn: true)
        apply(space: state.space, byID: state.surveys)
        if let target { _ = raise(target) }
        return (targets, duration)
    }

    /// After a slide under the overlay: wait for the real windows to stop at
    /// their targets (up to 0.4 s), correct the images onto where they
    /// actually landed, and hold two frames for apps to redraw.
    @discardableResult
    func finishHandoff(overlay: SnapshotTransition, targets: [UInt32: Rect], generation: UInt64,
                       interruptOnMouse: Bool = false) async -> (settled: Bool, landing: [UInt32: Rect], maxDeviation: Double)? {
        var previous: [UInt32: Rect] = [:]
        var result = (settled: false, landing: targets, maxDeviation: 0.0)
        for _ in 0..<16 {
            guard swipe?.generation == generation, !Task.isCancelled else { return nil }
            if interruptOnMouse && NSEvent.pressedMouseButtons != 0 {
                cancelMotion(); refreshOnMouseUp(); return nil
            }
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
        guard swipe?.generation == generation, !Task.isCancelled else { return nil }
        if result.maxDeviation > 0.5 {
            overlay.slide(to: result.landing, duration: 0.08)
            try? await Task.sleep(for: .milliseconds(90))
        }
        guard swipe?.generation == generation, !Task.isCancelled else { return nil }
        try? await Task.sleep(for: .milliseconds(34))
        guard swipe?.generation == generation, !Task.isCancelled else { return nil }
        return result
    }

    enum NewWindowMethod: String { case menu, key, launch, none }

    /// Opens a new window of the app: its "New Window" menu item when it has
    /// one (it means a window even where ⌘N opens a document or message, and
    /// needs no keyboard focus), else ⌘N while `wid` is its focused window.
    static func openNewWindow(pid: pid_t, window wid: UInt32) -> NewWindowMethod {
        if let item = newWindowMenuItem(pid: pid),
           AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return .menu }
        return sendCommand(keyN, to: pid, window: wid) ? .key : .none
    }

    /// The app's English "New Window" menu item, else a "New … Window" one
    /// (e.g. Finder's "New Finder Window"; never private or incognito). For
    /// a submenu (Terminal's profiles), its first enabled item. Titles are
    /// localised, so other languages fall back to ⌘N.
    static func newWindowMenuItem(pid: pid_t) -> AXUIElement? {
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
    func finishNewWindow(_ state: Swipe, window wid: UInt32) {
        let generation = state.generation, overlay = state.overlay
        let method: NewWindowMethod = state.pullAction == .openApp
            ? (openConfiguredApp() ? .launch : .none)
            : (pidForWindow[wid].map { Self.openNewWindow(pid: $0, window: wid) } ?? .none)
        let sent = method != .none
        if !sent { overlay.retractIndicator(duration: 0.18) }
        swipeMetrics["newWindow"] = method.rawValue
        swipeTask = Task { [weak self] in
            // One frame for the action to land before the fade.
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, self.swipe?.generation == generation, !Task.isCancelled else { return }
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil; self.resumeDeferredGestureSoon()
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
    func finishTabClose(_ state: Swipe, window wid: UInt32, mode: TabClose) {
        let generation = state.generation, overlay = state.overlay
        let released = ProcessInfo.processInfo.systemUptime
        let method: CloseMethod
        switch mode {
        case .native: method = pressClose(wid)
        case .app: method = pidForWindow[wid].map { Self.sendCommandW(to: $0, window: wid) ? .key : .none } ?? .none
        }
        swipeMetrics["closeMethod"] = method.rawValue
        swipeMetrics["tabClose"] = mode.rawValue
        if method == .key { focusManagedWindowAfterCommandW() }
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
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil; self.resumeDeferredGestureSoon()
            self.swipeMetrics["state"] = gone ? "tabClosed" : (method == .none ? "noCloseButton" : "closeRefused")
            self.swipeMetrics["closeMS"] = (ProcessInfo.processInfo.systemUptime - released) * 1000
            self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
            self.scheduleRefresh()
        }
    }

    /// Release towards the reducer’s chosen neighbour, or the progress side
    /// for simulations. A rejected commit slides back with no writes.
    func endSwipe(commit requested: Bool, direction requestedDirection: Direction? = nil) {
        defer {
            if running { windowIndicators.update(coordinator, mode: options.config.bottomDotsVisibility) }
        }
        guard var state = swipe, state.released == nil else { return }
        state.sampleTracking(at: CACurrentMediaTime())
        let direction: Direction = requestedDirection ?? (state.targetProgress < 0 ? .left : .right)
        let target = state.closing ? state.closeWindow : state.neighbours[direction]
        let commit = requested && (state.closing || requestedDirection != nil || state.targetProgress != 0) && target != nil
        // A caught swipe settles on its own column for real: the landing
        // it caught has already moved the windows to a different one.
        if state.caught && !commit { endCaughtSwipe(state, settle: max(0.12, options.config.focusScrollDuration ?? 0.22)); return }
        state.releaseDirection = direction
        let settle = max(0.12, options.config.focusScrollDuration ?? 0.22)
        if !state.ready { state.released = commit; swipe = state; return }
        if state.failed {
            swipe = nil
            swipeTask = nil
            resumeDeferredGestureSoon()
            scheduleRefresh()
            if commit, state.pulling, state.pullAction == .openApp {
                _ = openConfiguredApp()
            } else if commit, state.showsNewWindow, let wid = target, let pid = pidForWindow[wid] {
                _ = Self.openNewWindow(pid: pid, window: wid)
            } else if commit, state.pulling, state.pullAction == .minimize, let wid = target { _ = minimize(wid) }
            else if commit, state.closing, (!state.pulling || state.pullAction == .closeTab), let wid = target {
                if state.showsTabClose && state.tabCloseMode == .app, let pid = pidForWindow[wid] { _ = Self.sendCommandW(to: pid, window: wid) }
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
              let ends = state.ends[direction], let layout = state.layouts[direction] else {
            // Drop back from the speed the images had on screen.
            let back = state.progress < 0 ? state.visualVelocity : -state.visualVelocity
            let spring = SlotSwipe.Spring(distance: abs(state.progress), speed: back, response: settle)
            let duration = spring.duration
            // Follow the tracking path back so every image keeps the strip's speed.
            let from = state.progress, path = state
            overlay.slide(along: { u in self.swipeFrames(path, progress: from * (1 - u)) },
                          to: state.starts, spring: spring)
            if !state.closing {
                swipe?.landing = Landing(began: CACurrentMediaTime(), spring: spring,
                                         from: from, to: 0, frames: state.starts)
            }
            if state.showsIndicator { overlay.retractIndicator(duration: duration) }
            else if state.closing, let wid = state.closeWindow { overlay.fade(wid, to: 1, duration: duration) }
            swipeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 10))
                guard let self, self.swipe?.generation == generation else { return }
                overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil; self.resumeDeferredGestureSoon()
                self.swipeMetrics["state"] = "snappedBack"
                self.swipeMetrics["totalMS"] = (ProcessInfo.processInfo.systemUptime - self.swipeBegan) * 1000
                self.scheduleRefresh()
            }
            return
        }
        land(state, on: layout, window: wid, at: direction == .left ? -1 : 1, frames: ends, session: session, settle: settle)
    }

    /// A caught swipe released short of a neighbour settles on its own column.
    func endCaughtSwipe(_ state: Swipe, settle: Double) {
        var state = state
        guard let wid = state.baseWindow, let session = coordinator.sessions[state.space] else {
            cancelSwipe(); scheduleRefresh(); return
        }
        state.released = true
        swipe = state
        state.overlay.stopFrameClock()
        land(state, on: state.base, window: wid, at: 0, frames: state.center ?? state.starts, session: session, settle: settle)
    }

    /// Slides the images from where they are to `frames` (progress
    /// `destination`) while the real windows are placed once underneath for
    /// `layout`, then hands over to them. A new swipe may catch the slide.
    func land(_ state: Swipe, on layout: Layout, window wid: UInt32, at destinationProgress: Double,
                      frames ends: [UInt32: Rect], session: ScopedLayoutSession, settle: Double) {
        let generation = state.generation, space = state.space, overlay = state.overlay
        if state.caught, session.state.layout.columns != layout.columns {
            // The strip changed under a caught swipe; let a refresh place it.
            cancelSwipe(); scheduleRefresh(); return
        }
        // Land from the speed the strip had on screen, then slow onto the column.
        let distance = abs(destinationProgress - state.progress)
        let speed = destinationProgress > state.progress ? state.visualVelocity : -state.visualVelocity
        let spring = SlotSwipe.Spring(distance: distance, speed: speed, response: settle)
        let duration = spring.duration
        let from = state.progress, path = state
        // Start the landing first: it runs off the main thread, so the
        // synchronous window writes below cannot freeze it at release.
        overlay.slide(along: { u in
            self.swipeFrames(path, progress: from + (destinationProgress - from) * u)
        }, to: ends, spring: spring)
        swipe?.landing = Landing(began: CACurrentMediaTime(), spring: spring,
                                 from: from, to: destinationProgress, frames: ends)
        let released = ProcessInfo.processInfo.systemUptime
        // Same logical result as `focus`; one real placement under the overlay.
        try? session.focus(windowID: wid, ownerPID: pidForWindow[wid], classification: Self.tiled, ticket: session.ticket)
        if state.caught {
            // The column a caught swipe settles on may be revealed from a
            // different scroll position than the one the strip is at now.
            session.setOffset(layout.offset, ticket: session.ticket)
        } else {
            reveal(session)
        }
        applied.removeValue(forKey: space)
        // A caught swipe's survey frames are from before the landing it
        // caught moved the windows. `apply` skips a window whose target
        // matches its surveyed frame, so with those it would leave windows
        // where that landing put them (all of them when swiping back to the
        // start). Without a frame, every window is written.
        let byID = !state.caught ? state.surveys : state.surveys.mapValues {
            Survey(windowID: $0.windowID, pid: $0.pid, element: $0.element, classification: $0.classification,
                   facts: $0.facts, floatRequested: $0.floatRequested, spaceID: $0.spaceID, frame: nil)
        }
        apply(space: space, byID: byID)
        _ = raise(wid)
        let writesMS = (ProcessInfo.processInfo.systemUptime - released) * 1000
        swipeMetrics["releaseWritesMS"] = writesMS
        // Images for a further swipe from here, ready before it can begin.
        if let next = swipeDestinations(from: layout, session: session, surveys: state.surveys) {
            captureReachable(from: layout, ends: next.ends, state: state)
        }
        swipeTask = Task { [weak self] in
            // The slide began before the writes; wait out only what is left of it.
            try? await Task.sleep(for: .milliseconds(max(0, Int(duration * 1000 - writesMS))))
            // Hand off only once the real windows have stopped moving, then
            // finish the images on the frames they actually took.
            guard let self,
                  let result = await self.finishHandoff(overlay: overlay, targets: ends,
                                                       generation: generation, interruptOnMouse: true) else { return }
            overlay.fadeOut(); self.swipe = nil; self.swipeTask = nil; self.resumeDeferredGestureSoon()
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
    func simulateSwipe(_ direction: Direction, travel: Double) -> [String: Any] {
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
}
