import AppKit
import PaperiCore
import ScreenCaptureKit

/// Bottom UI above gesture overlays. Thumbnail clicks and drags never
/// activate the panel.
@MainActor final class WindowIndicators {
    private struct Presentation: Equatable {
        let space: UInt64
        let layout: Layout
        let canvas: Rect
        let mode: LiveConfig.Bottom
    }
    var onSelect: ((UInt32, UInt64) -> Void)?
    /// A thumbnail was dragged to a new position in tray order.
    var onMove: ((UInt32, Int, UInt64) -> Void)?
    private var panels: [String: NSPanel] = [:]
    private var presentations: [String: Presentation] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requestedCaptureAccess = false
    private var horizontalSwipeSpace: UInt64?
    /// Displays whose thumbnail tray was summoned to a point (AppKit screen
    /// coordinates). The tray stays there until it fades out.
    private var anchors: [String: CGPoint] = [:]

    /// Shows the thumbnail tray of `displayUUID`'s current Space centred on
    /// `point`. Returns false when that display has no tray to show.
    @discardableResult
    func summon(display displayUUID: String, at point: CGPoint,
                coordinator: DisplaySpaceCoordinator, mode: LiveConfig.Bottom) -> Bool {
        guard mode == .thumbnail,
              let space = coordinator.displays.first(where: { $0.displayUUID == displayUUID })?.activeSpaceID else { return false }
        anchors[displayUUID] = point
        update(coordinator, mode: mode, revealSpace: space)
        guard presentations[displayUUID]?.space == space else {
            anchors[displayUUID] = nil
            return false
        }
        return true
    }

    func activateHorizontalSwipe(in space: UInt64, coordinator: DisplaySpaceCoordinator, mode: LiveConfig.Bottom) {
        guard mode == .thumbnail else { return }
        horizontalSwipeSpace = space
        update(coordinator, mode: mode, revealSpace: space)
    }

    func finishHorizontalSwipe(coordinator: DisplaySpaceCoordinator, mode: LiveConfig.Bottom) {
        guard let space = horizontalSwipeSpace else { return }
        horizontalSwipeSpace = nil
        update(coordinator, mode: mode, revealSpace: space)
    }

    func hide() {
        horizontalSwipeSpace = nil
        anchors.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        presentations.removeAll()
        for panel in panels.values { panel.orderOut(nil) }
    }

    func update(_ coordinator: DisplaySpaceCoordinator, mode: LiveConfig.Bottom, revealSpace: UInt64? = nil) {
        guard mode != .none else { hide(); return }
        var visible = Set<String>()
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for display in coordinator.displays {
            guard let space = display.activeSpaceID,
                  display.userSpaces.contains(space),
                  let session = coordinator.sessions[space],
                  !session.state.interactionSuppressed else { continue }
            let layout = session.state.layout
            let slots = layout.columns.flatMap(\.slots)
            guard slots.count > 1 else { continue }
            let id = display.displayUUID
            visible.insert(id)
            let presentation = Presentation(space: space, layout: layout, canvas: display.canvas, mode: mode)
            // Refresh polls unchanged layouts once a second. They must not revive
            // the thumbnail strip or restart its dismissal deadline.
            guard presentations[id] != presentation || space == revealSpace else { continue }
            presentations[id] = presentation
            tasks[id]?.cancel()
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            let thumbnail = mode == .thumbnail
            panel.ignoresMouseEvents = !thumbnail
            let width = min(CGFloat(slots.count) * (thumbnail ? 116 : 14) + 20,
                            max(28, display.canvas.width - 32))
            let height: CGFloat = thumbnail ? 96 : 28
            let screen = NSRect(x: display.canvas.x, y: primaryTop - display.canvas.y - display.canvas.height,
                                width: display.canvas.width, height: display.canvas.height)
            var frame = NSRect(x: screen.minX + (screen.width - width) / 2, y: screen.minY + 12,
                               width: width, height: height)
            if thumbnail, let anchor = anchors[id] {
                // Centred on the pointer, kept on its display.
                frame.origin.x = min(max(anchor.x - width / 2, screen.minX + 8), screen.maxX - 8 - width)
                frame.origin.y = min(max(anchor.y - height / 2, screen.minY + 8), screen.maxY - 8 - height)
            }
            panel.setFrame(frame, display: false)
            guard let glass = panel.contentView else { continue }
            let cachedImages = (glass.subviews.first as? WindowPreviews)?.images ?? [:]
            glass.subviews.forEach { $0.removeFromSuperview() }
            if thumbnail {
                let previews = WindowPreviews(frame: NSRect(origin: .zero, size: frame.size))
                previews.ids = slots.map(\.activeMember)
                previews.onSelect = { [weak self] window in self?.onSelect?(window, space) }
                previews.onMove = { [weak self] window, position in self?.onMove?(window, position, space) }
                previews.images = cachedImages.filter { previews.ids.contains($0.key) }
                previews.selected = slots.firstIndex { $0.id == layout.focused }
                glass.addSubview(previews)
                if previews.images.isEmpty {
                    panel.orderOut(nil)
                } else {
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                }
                tasks[id] = Task { [weak self, weak panel] in
                    guard let self else { return }
                    var allowed = CGPreflightScreenCaptureAccess()
                    if !allowed && !self.requestedCaptureAccess {
                        self.requestedCaptureAccess = true
                        allowed = CGRequestScreenCaptureAccess()
                    }
                    guard allowed else { self.anchors[id] = nil; return }
                    guard !Task.isCancelled else { return }
                    do {
                        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                        for wid in previews.ids {
                            try Task.checkCancellation()
                            guard let window = content.windows.first(where: { $0.windowID == wid }) else { continue }
                            let filter = SCContentFilter(desktopIndependentWindow: window)
                            let config = SCStreamConfiguration()
                            let aspect = max(0.1, window.frame.width / max(1, window.frame.height))
                            config.width = 224
                            config.height = max(1, min(448, Int(224 / aspect)))
                            config.showsCursor = false
                            config.ignoreShadowsSingleWindow = true
                            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                            try Task.checkCancellation()
                            previews.images[wid] = NSImage(cgImage: image, size: .zero)
                        }
                        try Task.checkCancellation()
                        guard !previews.images.isEmpty else { return }
                        previews.needsDisplay = true
                        panel?.alphaValue = 1
                        panel?.orderFrontRegardless()
                        // Hovering anywhere in the strip holds it open, including
                        // its padding, as does a thumbnail drag that strays off it.
                        // Entering during a fade restores visibility; leaving
                        // starts a fresh two-second dismissal delay.
                        try await ThumbnailFade.run(delay: 2, shouldStayVisible: {
                            self.horizontalSwipeSpace == space || previews.isDragging ||
                                panel.map { $0.frame.contains(NSEvent.mouseLocation) } == true
                        }) { panel?.alphaValue = $0 }
                        try Task.checkCancellation()
                        panel?.orderOut(nil)
                        // The next reveal returns to the bottom of the display.
                        self.anchors[id] = nil
                    } catch {
                        // Cancellation leaves presentation to the newer refresh;
                        // unavailable captures never get replaced with fake previews.
                    }
                }
            } else {
                let dots = PageDots(frame: NSRect(origin: .zero, size: frame.size))
                dots.count = slots.count
                dots.selected = slots.firstIndex { $0.id == layout.focused }
                glass.addSubview(dots)
                panel.alphaValue = 1
                panel.orderFrontRegardless()
            }
        }
        for (id, panel) in panels where !visible.contains(id) {
            tasks.removeValue(forKey: id)?.cancel()
            presentations.removeValue(forKey: id)
            anchors.removeValue(forKey: id)
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        panel.contentView = glass
        return panel
    }
}

/// Thumbnails in tray order. Clicking one selects its window; dragging one
/// sideways reorders the tray live, and releasing commits the new position.
@MainActor private final class WindowPreviews: NSView {
    private struct Drag {
        let window: UInt32
        let from: Int
        /// Pointer x minus the grabbed cell's minX, so the cell keeps its grip.
        let grab: CGFloat
        var x: CGFloat
        var position: Int
    }
    var ids: [UInt32] = []
    var selected: Int?
    var images: [UInt32: NSImage] = [:]
    var onSelect: ((UInt32) -> Void)?
    var onMove: ((UInt32, Int) -> Void)?
    var isDragging: Bool { drag != nil }
    private var pressed: (window: UInt32, index: Int, point: NSPoint)?
    private var drag: Drag?

    private var cellWidth: CGFloat { (bounds.width - 20) / CGFloat(max(1, ids.count)) }

    private func cell(at index: Int) -> NSRect {
        NSRect(x: 10 + CGFloat(index) * cellWidth + 3, y: 10,
               width: max(1, cellWidth - 6), height: bounds.height - 20)
    }

    private func index(at point: NSPoint) -> Int? {
        ids.indices.first { cell(at: $0).contains(point) }
    }

    /// A refresh can rebuild the strip mid-drag; the drag ends with this view.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, drag != nil { drag = nil; NSCursor.pop() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = index(at: point).map { (ids[$0], $0, point) }
        drag = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed, ids.count > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if drag == nil {
            // A small wobble while clicking must not start a reorder.
            guard hypot(point.x - pressed.point.x, point.y - pressed.point.y) >= 4 else { return }
            drag = Drag(window: pressed.window, from: pressed.index,
                        grab: pressed.point.x - (10 + CGFloat(pressed.index) * cellWidth),
                        x: point.x, position: pressed.index)
            NSCursor.closedHand.push()
        }
        guard var current = drag else { return }
        current.x = point.x
        let left = point.x - current.grab - 10
        current.position = min(ids.count - 1, max(0, Int((left / cellWidth).rounded())))
        drag = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        if let finished = drag {
            drag = nil
            NSCursor.pop()
            needsDisplay = true
            guard finished.position != finished.from else { return }
            // Show the committed order until the layout refresh replaces it.
            let selectedWindow = selected.map { ids[$0] }
            ids.insert(ids.remove(at: finished.from), at: finished.position)
            selected = selectedWindow.flatMap { ids.firstIndex(of: $0) }
            onMove?(finished.window, finished.position)
            return
        }
        guard let pressed, index(at: convert(event.locationInWindow, from: nil)) == pressed.index else { return }
        onSelect?(pressed.window)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !ids.isEmpty else { return }
        var order = Array(ids.indices)
        if let drag { order.insert(order.remove(at: drag.from), at: drag.position) }
        for (slot, index) in order.enumerated() {
            let frame = cell(at: slot)
            if index == drag?.from {
                // The gap the dragged thumbnail will land in.
                let gap = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
                gap.setLineDash([4, 3], count: 2, phase: 0)
                gap.lineWidth = 1.5
                NSColor.white.withAlphaComponent(0.5).setStroke()
                gap.stroke()
            } else {
                drawThumbnail(index, in: frame)
            }
        }
        if let drag {
            var frame = cell(at: drag.from)
            frame.origin.x = min(max(0, drag.x - drag.grab + 3), bounds.width - frame.width)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 8
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.set()
            drawThumbnail(drag.from, in: frame.insetBy(dx: -2, dy: -2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawThumbnail(_ index: Int, in cell: NSRect) {
        let path = NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(drag?.from == index ? 0.2 : 0.1).setFill()
        path.fill()
        if let image = images[ids[index]] {
            let scale = min((cell.width - 4) / image.size.width, (cell.height - 4) / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
        if index == selected {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}

@MainActor private final class PageDots: NSView {
    var count = 0
    var selected: Int?

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let spacing = min(14, (bounds.width - 20) / CGFloat(count))
        let diameter = min(6, spacing * 0.65)
        let start = bounds.midX - CGFloat(count - 1) * spacing / 2
        for index in 0..<count {
            NSColor.white.withAlphaComponent(index == selected ? 1 : 0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: start + CGFloat(index) * spacing - diameter / 2,
                                       y: bounds.midY - diameter / 2,
                                       width: diameter, height: diameter)).fill()
        }
    }
}

/// A task-owned fade. AppKit animator animations continue after task cancellation;
/// explicit opacity updates stop at the next suspension when a reveal supersedes them.
@MainActor enum ThumbnailFade {
    static func run(duration: TimeInterval = 0.2, delay: TimeInterval = 0,
                    shouldStayVisible: () -> Bool = { false }, setOpacity: (Double) -> Void) async throws {
        var started = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            let held = shouldStayVisible()
            if held { started = now }
            let elapsed = max(0, now - started - delay)
            let progress = held || now - started < delay ? 0 : duration > 0 ? min(1, elapsed / duration) : 1
            setOpacity(1 - progress)
            if progress >= 1 { return }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}
