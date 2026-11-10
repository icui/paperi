import AppKit
import PaperiCore

/// Click-through, semi-transparent mask over the column a dragged window
/// would swap with. Ordered just above that column's window so the dragged
/// (frontmost) window stays on top of it.
@MainActor final class SwapHighlight {
    private var window: NSWindow?

    func show(_ rect: Rect, color: HexColor, above windowID: UInt32?) {
        let window = self.window ?? make()
        self.window = window
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        window.contentView?.layer?.backgroundColor = CGColor(srgbRed: color.red, green: color.green,
                                                             blue: color.blue, alpha: color.alpha)
        window.setFrame(NSRect(x: rect.x, y: primaryHeight - rect.y - rect.height, width: rect.width, height: rect.height),
                        display: true)
        if let windowID { window.order(.above, relativeTo: Int(windowID)) } else { window.orderFrontRegardless() }
    }

    func hide() { window?.orderOut(nil) }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        window.contentView = view
        return window
    }
}
