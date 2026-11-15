import AppKit
@preconcurrency import ApplicationServices
import PaperiBridge
import PaperiCore

/// Gap resize: dragging the gap between two tiled windows resizes both,
/// keeping their outer edges (and so the rest of the strip) in place.
/// Hover tracking runs on mouse-moved monitors; the handle itself
/// (`DividerHandle`) shows only while the pointer is over the middle of an
/// exposed gap; elsewhere the gap is left to the windows' own resizing.
extension LiveManager {
    func startDividers() {
        stopDividers()
        guard options.config.gapResize else { return }
        _ = paperi_set_cursor_in_background(true)
        dividerHandle.onBegin = { [weak self] x, y in self?.beginDividerDrag(x: x, y: y) }
        dividerHandle.onDrag = { [weak self] x, y in self?.continueDividerDrag(x: x, y: y) }
        dividerHandle.onEnd = { [weak self] in self?.finishDividerDrag() }
        let moved = { [weak self] in MainActor.assumeIsolated { self?.updateDividerHover() } }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in moved() }) {
            dividerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in moved(); return event }) {
            dividerMonitors.append(local)
        }
    }

    func stopDividers() {
        for monitor in dividerMonitors { NSEvent.removeMonitor(monitor) }
        if !dividerMonitors.isEmpty { _ = paperi_set_cursor_in_background(false) }
        dividerMonitors.removeAll()
        if dividerDrag != nil { finishDividerDrag(refreshing: false) }
        dividerHover = nil
        dividerHandle.hide()
    }

    static func pointer() -> (x: Double, y: Double) {
        let point = NSEvent.mouseLocation
        return (Double(point.x), Double(NSScreen.screens.first?.frame.height ?? 0) - Double(point.y))
    }

    /// Shows the handle while the pointer is anywhere along an exposed gap
    /// of an active strip (within `DividerHandle.hoverWidth` across it), and
    /// hides it otherwise (or during any other interaction). Only the middle
    /// segment takes clicks; see `DividerHandle`.
    func updateDividerHover() {
        guard dividerDrag == nil else { return }
        guard running, !paused, options.config.gapResize, !motionActive, drag == nil,
              NSEvent.pressedMouseButtons == 0, let hover = dividerUnderPointer() else {
            if dividerHover != nil || dividerHandle.isShown { dividerHover = nil; dividerHandle.hide() }
            return
        }
        dividerHover = hover
        let (x, y) = Self.pointer()
        let inGrab = hover.shown.contains(x: x, y: y, hitWidth: DividerHandle.grabWidth, length: DividerHandle.grabLength)
        dividerHandle.show(hover.shown, inGrab: inGrab, accent: options.config.swapHighlightColor)
    }

    func dividerUnderPointer() -> (space: UInt64, region: DividerRegion, shown: DividerRegion)? {
        let (x, y) = Self.pointer()
        var windows: [CGRect]?
        var bounds: [UInt32: CGRect] = [:]
        for display in coordinator.displays {
            guard let space = display.activeSpaceID, let session = coordinator.sessions[space],
                  !session.state.interactionSuppressed else { continue }
            let c = session.canvas
            guard x >= c.x, x < c.x + c.width, y >= c.y, y < c.y + c.height,
                  let regions = try? session.state.layout.dividers(in: c, gap: options.gap) else { continue }
            let near = regions.filter { $0.contains(x: x, y: y, hitWidth: DividerHandle.hoverWidth + 96, length: .infinity) }
            guard !near.isEmpty else { continue }
            if windows == nil { (windows, bounds) = Self.onScreenWindows() }
            for region in near {
                let shown = Self.visibleGap(region, in: session.state.layout, bounds: bounds)
                guard shown.contains(x: x, y: y, hitWidth: DividerHandle.hoverWidth, length: .infinity) else { continue }
                // Probe the gap itself, not the pointer, which may be on a window edge.
                let g = shown.gap
                let probe = shown.divider.isVertical
                    ? CGPoint(x: shown.position, y: min(max(y, g.y), g.y + g.height - 1))
                    : CGPoint(x: min(max(x, g.x), g.x + g.width - 1), y: shown.position)
                return windows!.contains { $0.contains(probe) } ? nil : (space, region, shown)
            }
        }
        return nil
    }

    /// One on-screen window list: the frames of windows that would cover a
    /// gap (normal to modal-panel level, visible, not Paperi's), since tiled
    /// windows never do, and the actual bounds of every window by ID.
    static func onScreenWindows() -> (covering: [CGRect], bounds: [UInt32: CGRect]) {
        let own = ProcessInfo.processInfo.processIdentifier
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var covering: [CGRect] = [], bounds: [UInt32: CGRect] = [:]
        for row in rows {
            guard let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { continue }
            if let id = row[kCGWindowNumber as String] as? UInt32 { bounds[id] = rect }
            if let layer = row[kCGWindowLayer as String] as? Int, (0...8).contains(layer),
               row[kCGWindowOwnerPID as String] as? pid_t != own,
               (row[kCGWindowAlpha as String] as? Double ?? 1) > 0 { covering.append(rect) }
        }
        return (covering, bounds)
    }

    /// The gap as actually on screen: apps that size in steps (terminal
    /// character cells) or clamp to a minimum leave it off the layout's, so
    /// the handle is centred between the windows' real edges. Falls back to
    /// the layout's gap if a window is missing or the edges overlap.
    ///
    /// `anchor` (mid-drag): the windows lag the pointer, each by its own
    /// app's delay, so their edges disagree. Centring between them, or
    /// switching between them, makes the bar jump; instead it keeps the
    /// layout's spacing from one window's edge for the whole drag (true: the
    /// leading, left / upper, window's far edge; false: the trailing one's
    /// near edge), and never falls back to the layout, which runs ahead.
    static func visibleGap(_ region: DividerRegion, in layout: Layout, bounds: [UInt32: CGRect],
                           anchor: Bool? = nil) -> DividerRegion {
        let columns = layout.columns
        let spacing = region.divider.isVertical ? region.gap.width : region.gap.height
        func edges(_ lo: Double, _ hi: Double) -> (lo: Double, hi: Double)? {
            switch anchor {
            case true?: return (lo, lo + spacing)
            case false?: return (hi - spacing, hi)
            case nil: return hi >= lo ? (lo, hi) : nil
            }
        }
        let tracking = anchor != nil
        switch region.divider {
        case .columns(let c):
            func frames(_ slots: [Slot]) -> [CGRect]? {
                let found = slots.compactMap { bounds[$0.activeMember] }
                return found.count == slots.count ? found : nil
            }
            guard columns.indices.contains(c + 1), let a = frames(columns[c].slots), let b = frames(columns[c + 1].slots),
                  let lo = a.map({ Double($0.maxX) }).max(), let hi = b.map({ Double($0.minX) }).min(),
                  let e = edges(lo, hi),
                  tracking || abs((e.lo + e.hi) / 2 - region.position) < 48 else { return region }
            return DividerRegion(divider: region.divider,
                                 gap: Rect(x: e.lo, y: region.gap.y, width: e.hi - e.lo, height: region.gap.height),
                                 position: (e.lo + e.hi) / 2)
        case .rows(let c, let r):
            guard columns.indices.contains(c), r + 1 < columns[c].slots.count,
                  let above = bounds[columns[c].slots[r].activeMember], let below = bounds[columns[c].slots[r + 1].activeMember],
                  let e = edges(Double(above.maxY), Double(below.minY))
            else { return region }
            let left = max(region.gap.x, Double(max(above.minX, below.minX)))
            let right = min(region.gap.x + region.gap.width, Double(min(above.maxX, below.maxX)))
            guard right > left, tracking || abs((e.lo + e.hi) / 2 - region.position) < 48 else { return region }
            return DividerRegion(divider: region.divider, gap: Rect(x: left, y: e.lo, width: right - left, height: e.hi - e.lo),
                                 position: (e.lo + e.hi) / 2)
        }
    }

    /// Current screen bounds of just these windows (cheaper than the full list).
    static func bounds(of windows: [UInt32]) -> [UInt32: CGRect] {
        var ids: [UnsafeRawPointer?] = windows.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = ids.withUnsafeMutableBufferPointer({ CFArrayCreate(nil, $0.baseAddress, $0.count, nil) }),
              let rows = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [:] }
        var result: [UInt32: CGRect] = [:]
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let dictionary = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary) else { continue }
            result[id] = rect
        }
        return result
    }

    /// Mid-drag, keeps the handle on the windows' actual edges every frame,
    /// including after the pointer stops while the apps catch up.
    func trackDividerWindows() {
        guard let current = dividerDrag, let session = coordinator.sessions[current.space],
              let region = try? session.state.layout.dividers(in: session.canvas, gap: options.gap)
                .first(where: { $0.divider == current.divider }) else { return }
        let columns = session.state.layout.columns
        let windows: [UInt32]
        switch current.divider {
        case .columns(let c): windows = (columns[c].slots + columns[c + 1].slots).map(\.activeMember)
        case .rows(let c, let r): windows = [columns[c].slots[r].activeMember, columns[c].slots[r + 1].activeMember]
        }
        let shown = Self.visibleGap(region, in: session.state.layout, bounds: Self.bounds(of: windows), anchor: current.anchorLeading)
        dividerHandle.show(shown, inGrab: true, accent: options.config.swapHighlightColor)
    }

    func beginDividerDrag(x: Double, y: Double) {
        guard let hover = dividerHover, coordinator.sessions[hover.space] != nil else { return }
        cancelMotion(); motionFrames.removeAll()
        let along = hover.region.divider.isVertical ? x : y
        // Against the layout's gap, so the layout follows the pointer exactly.
        // Anchor the bar to the smaller window: it redraws faster, so its
        // edge keeps closest to the pointer.
        let layout = coordinator.sessions[hover.space]!.state.layout
        let leadingSmaller: Bool
        switch hover.region.divider {
        case .columns(let c): leadingSmaller = layout.columns[c].width <= layout.columns[c + 1].width
        case .rows(let c, let r): leadingSmaller = layout.columns[c].weights[r] <= layout.columns[c].weights[r + 1]
        }
        dividerDrag = DividerDrag(space: hover.space, divider: hover.region.divider, grab: along - hover.region.position,
                                  anchorLeading: leadingSmaller)
        dividerTimer?.invalidate()
        dividerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackDividerWindows() }
        }
        RunLoop.main.add(dividerTimer!, forMode: .eventTracking)
        log("gap drag began on \(hover.region.divider) in Space \(hover.space)")
    }

    func continueDividerDrag(x: Double, y: Double) {
        guard var current = dividerDrag, let session = coordinator.sessions[current.space] else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 { finishDividerDrag(); return }
        let along = current.divider.isVertical ? x : y
        // A window that refuses a size gets it as its limit and the move is
        // redone: refusing to shrink stops the gap, refusing to grow makes the
        // window travel with it.
        for _ in 0 ..< 3 {
            guard session.moveDivider(current.divider, to: along - current.grab, gap: options.gap,
                                      minimums: current.minimums, maximums: current.maximums,
                                      ticket: session.ticket) else { break }
            let refused = writeDividerFrames(current)
            guard !refused.minimums.isEmpty || !refused.maximums.isEmpty else { break }
            current.minimums.merge(refused.minimums) { max($0, $1) }
            current.maximums.merge(refused.maximums) { min($0, $1) }
            dividerDrag = current
            log("gap drag learned minimums \(refused.minimums) maximums \(refused.maximums)")
        }
        trackDividerWindows()
    }

    func finishDividerDrag(refreshing: Bool = true) {
        guard let current = dividerDrag else { return }
        dividerDrag = nil
        dividerTimer?.invalidate(); dividerTimer = nil
        log("gap drag ended on \(current.divider)")
        rememberWidths()
        applied.removeValue(forKey: current.space)
        forceApply = true
        if refreshing { refresh() }
    }

    /// Writes the windows that moved: those beside the dragged gap and, once
    /// a side travels with the gap, the strip beyond it. The full apply pass
    /// (and its survey) is skipped mid-drag. Returns the sizes along the drag
    /// axis of slots whose app refused to shrink / grow to its target.
    @discardableResult
    func writeDividerFrames(_ current: DividerDrag) -> (minimums: [String: Double], maximums: [String: Double]) {
        guard let session = coordinator.sessions[current.space],
              let placements = try? session.state.layout.placements(in: session.canvas, gap: options.gap) else { return ([:], [:]) }
        let tucked = LiveReconciliation.tuck(LiveReconciliation.edgeItems(placements),
                                             canvas: session.canvas, screenInset: options.outerGap)
        let now = ProcessInfo.processInfo.systemUptime
        // The growing window goes first, so its neighbour never pulls back
        // before it has covered the space and the desktop never shows through.
        let moves: [(wid: UInt32, slot: String, element: AXUIElement, from: Rect?, to: Rect)] = placements.compactMap { placement in
            let wid = placement.windowID
            let target = tucked[wid] ?? placement.frame
            guard let element = references[wid], expected[wid]?.frame != target else { return nil }
            return (wid, placement.slotID, element, expected[wid]?.frame, target)
        }.sorted { ($0.to.width * $0.to.height - ($0.from.map { $0.width * $0.height } ?? 0)) >
                   ($1.to.width * $1.to.height - ($1.from.map { $0.width * $0.height } ?? 0)) }
        var minimums: [String: Double] = [:], maximums: [String: Double] = [:]
        let vertical = current.divider.isVertical
        for move in moves {
            session.expect(windowID: move.wid, frame: move.to, now: now, ticket: session.ticket)
            expected[move.wid] = (move.to, now)
            guard let size = writeDividerFrame(move.to, from: move.from, to: move.element) else {
                log("gap drag write failed for \(move.wid)"); continue
            }
            // Refused only if it did not change size at all: an app that
            // sizes in steps (terminal cells) lands near, not at, the target
            // and must keep resizing.
            let actual = Double(vertical ? size.width : size.height), wanted = vertical ? move.to.width : move.to.height
            guard let previous = move.from.map({ vertical ? $0.width : $0.height }) else { continue }
            if wanted < previous - 1, actual > wanted + 1, actual >= previous - 1, actual > current.minimums[move.slot] ?? 0 {
                minimums[move.slot] = actual
            } else if wanted > previous + 1, actual < wanted - 1, actual <= previous + 1,
                      actual < current.maximums[move.slot] ?? .infinity {
                maximums[move.slot] = actual
            }
        }
        return (minimums, maximums)
    }

    /// Writes only what changed, ordered so the window briefly overlaps its
    /// neighbour rather than leaving a gap: a growing window is sized before
    /// it is moved, a shrinking one moved before it is sized. Each change is
    /// one AX write, against three for a general placement (`write`).
    /// Returns the size the app actually took (read back, since an app at its
    /// minimum clamps the write), or nil if a write failed.
    func writeDividerFrame(_ frame: Rect, from previous: Rect?, to element: AXUIElement) -> CGSize? {
        func readSize() -> CGSize? {
            guard let value = Diagnostics.attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
        }
        guard let previous else { return write(frame, to: element) ? readSize() : nil }
        let start = ProcessInfo.processInfo.systemUptime
        var point = CGPoint(x: frame.x, y: frame.y), size = CGSize(width: frame.width, height: frame.height)
        guard let p = AXValueCreate(.cgPoint, &point), let s = AXValueCreate(.cgSize, &size) else { return nil }
        let moved = previous.x != frame.x || previous.y != frame.y
        let resized = previous.width != frame.width || previous.height != frame.height
        let growing = frame.width * frame.height > previous.width * previous.height
        var writes: [(CFString, AXValue)] = []
        if resized && growing { writes.append((kAXSizeAttribute as CFString, s)) }
        if moved { writes.append((kAXPositionAttribute as CFString, p)) }
        if resized && !growing { writes.append((kAXSizeAttribute as CFString, s)) }
        var ok = true
        for (name, value) in writes { ok = AXUIElementSetAttributeValue(element, name, value) == .success && ok }
        axWriteCalls += writes.count; axWriteMS += (ProcessInfo.processInfo.systemUptime - start) * 1000
        guard ok else { return nil }
        return resized ? readSize() : size
    }
}
