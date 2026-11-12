import AppKit
import PaperiCore
import ScreenCaptureKit

/// Bottom UI above gesture overlays. Thumbnail clicks never activate the panel.
@MainActor final class WindowIndicators {
    private struct Presentation: Equatable {
        let space: UInt64
        let layout: Layout
        let canvas: Rect
        let mode: LiveConfig.Bottom
    }
    var onSelect: ((UInt32, UInt64) -> Void)?
    private var panels: [String: NSPanel] = [:]
    private var presentations: [String: Presentation] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var requestedCaptureAccess = false
    private var horizontalSwipeSpace: UInt64?

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
            let frame = NSRect(x: display.canvas.x + (display.canvas.width - width) / 2,
                               y: primaryTop - display.canvas.y - display.canvas.height + 12,
                               width: width, height: thumbnail ? 96 : 28)
            panel.setFrame(frame, display: false)
            guard let glass = panel.contentView else { continue }
            let cachedImages = (glass.subviews.first as? WindowPreviews)?.images ?? [:]
            glass.subviews.forEach { $0.removeFromSuperview() }
            if thumbnail {
                let previews = WindowPreviews(frame: NSRect(origin: .zero, size: frame.size))
                previews.ids = slots.map(\.activeMember)
                previews.onSelect = { [weak self] window in self?.onSelect?(window, space) }
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
                    guard allowed, !Task.isCancelled else { return }
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
                        try await Task.sleep(for: .seconds(2))
                        try Task.checkCancellation()
                        guard self.horizontalSwipeSpace != space else { return }
                        // Run opacity updates in this task so a new show request
                        // cancels the fade itself, not just its completion handler.
                        try await ThumbnailFade.run { panel?.alphaValue = $0 }
                        try Task.checkCancellation()
                        panel?.orderOut(nil)
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

@MainActor private final class WindowPreviews: NSView {
    var ids: [UInt32] = []
    var selected: Int?
    var images: [UInt32: NSImage] = [:]
    var onSelect: ((UInt32) -> Void)?
    private var pressedWindow: UInt32?

    private func window(at point: NSPoint) -> UInt32? {
        guard !ids.isEmpty else { return nil }
        let width = (bounds.width - 20) / CGFloat(ids.count)
        return ids.enumerated().first { index, _ in
            NSRect(x: 10 + CGFloat(index) * width + 3, y: 10,
                   width: max(1, width - 6), height: bounds.height - 20).contains(point)
        }?.element
    }

    override func mouseDown(with event: NSEvent) {
        pressedWindow = window(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedWindow = nil }
        guard let id = pressedWindow, window(at: convert(event.locationInWindow, from: nil)) == id else { return }
        onSelect?(id)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !ids.isEmpty else { return }
        let cellWidth = (bounds.width - 20) / CGFloat(ids.count)
        for (index, id) in ids.enumerated() {
            let cell = NSRect(x: 10 + CGFloat(index) * cellWidth + 3, y: 10,
                              width: max(1, cellWidth - 6), height: bounds.height - 20)
            let path = NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.1).setFill()
            path.fill()
            if let image = images[id] {
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
    static func run(duration: TimeInterval = 0.2, setOpacity: (Double) -> Void) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let progress = duration > 0 ? min(1, elapsed / duration) : 1
            setOpacity(1 - progress)
            if progress >= 1 { return }
            try await Task.sleep(for: .milliseconds(8))
        }
    }
}
