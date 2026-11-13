import AppKit
@preconcurrency import ApplicationServices
import PaperiBridge
import PaperiCore

/// Keyboard focus scroll: position-only AX writes on real windows.
extension LiveManager {
    func cancelMotion() {
        cancelSwipe()
        motionGeneration &+= 1
        motionTimer?.invalidate(); motionTimer = nil
        motionBounce = nil
    }

    /// Reveal an existing representative before the expensive all-app survey.
    /// WindowServer supplies current frames; unknown windows still take the full
    /// reconciliation path. A normal refresh follows animation completion.
    func animateCachedFocus() -> Bool {
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
    func cachedStripSurveys(space: UInt64, placements: [Placement]) -> [UInt32: Survey]? {
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
    func animateFocus(space: UInt64, byID: [UInt32: Survey], bounce: Direction? = nil) {
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
            guard LiveReconciliation.animationSizeMatches(frame, target) else {
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
    func confirmFocus(targets: [UInt32: Rect], generation: UInt64, attempts: Int) {
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
}
