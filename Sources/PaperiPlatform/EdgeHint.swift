import AppKit
import PaperiCore

/// Gentle "end of the row" cue: a short accent-coloured bar fades in and out
/// along one edge of the focused window when focus cannot move that way.
/// Click-through and above all windows; it never takes focus.
@MainActor final class EdgeHint {
    private var window: NSWindow?
    private var generation = 0

    /// Bar frame (AX coordinates, top-left origin) along `side` of `frame`.
    nonisolated static func bar(along frame: Rect, side: Direction, thickness: Double = 5, inset: Double = 6) -> Rect {
        switch side {
        case .left, .right:
            let length = frame.height * 0.6
            let x = side == .left ? frame.x + inset : frame.x + frame.width - inset - thickness
            return Rect(x: x, y: frame.y + (frame.height - length) / 2, width: thickness, height: length)
        case .up, .down:
            let length = frame.width * 0.6
            let y = side == .up ? frame.y + inset : frame.y + frame.height - inset - thickness
            return Rect(x: frame.x + (frame.width - length) / 2, y: y, width: length, height: thickness)
        }
    }

    func show(along frame: Rect, side: Direction) {
        let window = self.window ?? make()
        self.window = window
        let rect = Self.bar(along: frame, side: side)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        window.setFrame(NSRect(x: rect.x, y: primaryHeight - rect.y - rect.height, width: rect.width, height: rect.height),
                        display: true)
        window.contentView?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        generation += 1
        let current = generation
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.35
                        window.animator().alphaValue = 0
                    }, completionHandler: {
                        MainActor.assumeIsolated { if self.generation == current { window.orderOut(nil) } }
                    })
                }
            }
        })
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 2.5
        window.contentView = view
        return window
    }
}
