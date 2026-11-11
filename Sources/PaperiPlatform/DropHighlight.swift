import AppKit
import PaperiCore

/// Click-through overlay over the window a dragged window would be dropped
/// on. It floats above every normal window, the dragged one included, so the
/// preview stays visible while the dragged window covers the target. It shows, in the `swapHighlight` colour:
/// - a light tint over the whole target with dashed guides at the zone edges
///   (top/bottom quarters for another column, left/right quarters for the
///   dragged window's own stack), so the other drops are discoverable;
/// - a stronger preview of where the dragged window will land (the whole
///   target for a swap, the half it will take for a stack or new column);
/// - a label naming the drop.
@MainActor final class DropHighlight {
    private var window: NSWindow?
    private let base = CALayer()
    private let guides = CAShapeLayer()
    private let preview = CALayer()
    private let pill = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var shown: SwapTarget?

    func show(_ target: SwapTarget, action: DropAction, color: HexColor) {
        let window = self.window ?? make()
        self.window = window
        let rect = target.region
        let sameTarget = shown == target && window.isVisible
        shown = target
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if !sameTarget {
            window.setFrame(NSRect(x: rect.x, y: primaryHeight - rect.y - rect.height, width: rect.width, height: rect.height),
                            display: false)
        }
        let bounds = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        let tint = { (alpha: Double) in CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha) }

        CATransaction.begin()
        // Moving between zones of one target slides the preview; a new target jumps.
        CATransaction.setDisableActions(!sameTarget)
        CATransaction.setAnimationDuration(0.12)
        base.frame = bounds
        base.backgroundColor = tint(color.alpha * 0.45)
        guides.frame = bounds
        guides.path = Self.guidePath(bounds, vertical: target.sameColumn)
        let landing = Self.landing(action, in: bounds)
        preview.frame = landing
        preview.backgroundColor = tint(max(color.alpha, 0.3))
        preview.borderColor = tint(0.9)
        CATransaction.commit()

        let (title, symbol) = Self.describe(action, sameColumn: target.sameColumn)
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.isHidden = icon.image == nil
        let iconWidth: CGFloat = icon.isHidden ? 0 : 22
        let size = NSSize(width: iconWidth + label.intrinsicContentSize.width + 24, height: 30)
        pill.frame = NSRect(x: landing.midX - size.width / 2, y: landing.midY - size.height / 2,
                            width: size.width, height: size.height)
        icon.frame = NSRect(x: 10, y: 5, width: 20, height: 20)
        label.frame = NSRect(x: 10 + iconWidth, y: (size.height - label.intrinsicContentSize.height) / 2,
                             width: label.intrinsicContentSize.width + 2, height: label.intrinsicContentSize.height)
        pill.isHidden = size.width + 8 > landing.width || size.height + 8 > landing.height

        if !sameTarget { window.orderFrontRegardless() }
    }

    func hide() { window?.orderOut(nil); shown = nil }

    /// Where the dragged window will land, in the overlay's top-left space.
    private static func landing(_ action: DropAction, in bounds: CGRect) -> CGRect {
        let inset: CGFloat = 6, gap: CGFloat = 3
        let r = bounds.insetBy(dx: min(inset, bounds.width / 4), dy: min(inset, bounds.height / 4))
        switch action {
        case .swap: return r
        case .stackAbove: return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2 - gap)
        case .stackBelow: return CGRect(x: r.minX, y: r.midY + gap, width: r.width, height: r.height / 2 - gap)
        case .newColumnLeft: return CGRect(x: r.minX, y: r.minY, width: r.width / 2 - gap, height: r.height)
        case .newColumnRight: return CGRect(x: r.midX + gap, y: r.minY, width: r.width / 2 - gap, height: r.height)
        }
    }

    /// Dashed lines at the edge-zone boundaries: horizontal for another
    /// column's window (stack above/below), vertical within one's own stack.
    private static func guidePath(_ bounds: CGRect, vertical: Bool) -> CGPath {
        let path = CGMutablePath()
        for f in [SwapTarget.edgeZone, 1 - SwapTarget.edgeZone] {
            if vertical {
                let x = bounds.width * f
                path.move(to: CGPoint(x: x, y: 12)); path.addLine(to: CGPoint(x: x, y: bounds.height - 12))
            } else {
                let y = bounds.height * f
                path.move(to: CGPoint(x: 12, y: y)); path.addLine(to: CGPoint(x: bounds.width - 12, y: y))
            }
        }
        return path
    }

    private static func describe(_ action: DropAction, sameColumn: Bool) -> (String, String) {
        switch action {
        case .swap: return ("Swap", sameColumn ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
        case .stackAbove: return ("Stack above", "rectangle.tophalf.inset.filled")
        case .stackBelow: return ("Stack below", "rectangle.bottomhalf.inset.filled")
        case .newColumnLeft: return ("New column left", "rectangle.lefthalf.inset.filled")
        case .newColumnRight: return ("New column right", "rectangle.righthalf.inset.filled")
        }
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
        let view = FlippedView()
        view.wantsLayer = true
        base.cornerRadius = 10
        guides.fillColor = nil
        guides.strokeColor = CGColor(gray: 1, alpha: 0.55)
        guides.lineWidth = 1.5
        guides.lineDashPattern = [6, 5]
        preview.cornerRadius = 8
        preview.borderWidth = 2
        for layer in [base, guides, preview] { view.layer?.addSublayer(layer) }

        pill.wantsLayer = true
        pill.layer?.backgroundColor = CGColor(gray: 0, alpha: 0.6)
        pill.layer?.cornerRadius = 15
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        pill.addSubview(icon); pill.addSubview(label)
        view.addSubview(pill)
        window.contentView = view
        return window
    }

    /// Top-left origin, matching the layout's screen coordinates.
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
}
