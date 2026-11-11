import AppKit

/// Pixel-sized companion to the three symmetric panes in the app icon.
@MainActor enum BrandIcon {
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            // A broad active sheet with two compact peripheral cards.
            NSColor.black.setFill()
            for x in [1.0, 16.0] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 5, width: 3, height: 8),
                             xRadius: 1, yRadius: 1).fill()
            }
            let active = NSBezierPath(roundedRect: NSRect(x: 6, y: 3, width: 8, height: 12),
                                      xRadius: 1.5, yRadius: 1.5)
            NSColor.black.withAlphaComponent(0.16).setFill()
            active.fill()
            NSColor.black.setStroke()
            active.lineWidth = 1
            active.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Paperi"
        return image
    }

    static func install(on button: NSStatusBarButton?) {
        button?.image = menuBar()
        button?.imagePosition = .imageLeading
        button?.title = ""
        button?.setAccessibilityLabel("Paperi")
        button?.toolTip = "Paperi"
    }
}
