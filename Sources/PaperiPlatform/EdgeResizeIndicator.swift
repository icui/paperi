import AppKit
import PaperiCore

/// Marks the edge a Shift + trackpad resize is moving: one white bar just
/// inside the focused window's edge, following the requested position.
/// Unlike the gap handle's two opposing arrows, which say that both windows
/// beside a gap resize, it sits on the one window being resized.
///
/// The panel never activates Paperi and lets every click through.
@MainActor final class EdgeResizeIndicator {
    /// Bar thickness, length along the edge (at most), and gap from the edge.
    nonisolated static let thickness = 5.0
    nonisolated static let length = 96.0
    nonisolated static let inset = 4.0

    nonisolated enum Edge: Sendable { case left, right, top, bottom }

    private var panel: NSPanel?
    private let bar = CAShapeLayer()

    /// Shows (or moves) the bar inside `window`'s `edge` (screen
    /// coordinates, top-left origin).
    func show(_ edge: Edge, of window: Rect) {
        let rect = Self.bar(edge, of: window), t = Self.thickness
        // Room for the shadow around the bar.
        let pad = 4.0
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let frame = NSRect(x: (rect.x - pad).rounded(), y: (primaryHeight - rect.y - rect.height - pad).rounded(),
                           width: (rect.width + 2 * pad).rounded(), height: (rect.height + 2 * pad).rounded())
        let panel = self.panel ?? make()
        self.panel = panel
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.frame = CGRect(origin: .zero, size: frame.size)
        let shape = CGRect(x: pad, y: pad, width: frame.width - 2 * pad, height: frame.height - 2 * pad)
        bar.path = CGPath(roundedRect: shape, cornerWidth: t / 2, cornerHeight: t / 2, transform: nil)
        CATransaction.commit()
        panel.displayIfNeeded()
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    /// The bar: centred along `edge`, `inset` inside it.
    nonisolated static func bar(_ edge: Edge, of window: Rect) -> Rect {
        let vertical = edge == .left || edge == .right
        let along = min(length, max(16, (vertical ? window.height : window.width) - 16))
        let t = thickness, i = inset
        switch edge {
        case .right: return Rect(x: window.x + window.width - i - t, y: window.y + (window.height - along) / 2, width: t, height: along)
        case .left: return Rect(x: window.x + i, y: window.y + (window.height - along) / 2, width: t, height: along)
        case .bottom: return Rect(x: window.x + (window.width - along) / 2, y: window.y + window.height - i - t, width: along, height: t)
        case .top: return Rect(x: window.x + (window.width - along) / 2, y: window.y + i, width: along, height: t)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        bar.fillColor = CGColor(gray: 1, alpha: 1)
        bar.shadowColor = CGColor(gray: 0, alpha: 1)
        bar.shadowOpacity = 0.65
        bar.shadowRadius = 2
        bar.shadowOffset = .zero
        view.layer?.addSublayer(bar)
        panel.contentView = view
        return panel
    }
}
