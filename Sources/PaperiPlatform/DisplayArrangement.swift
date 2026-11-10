import AppKit

/// Paperi scrolls windows sideways off a display's left and right edges. A
/// window past an edge that touches another display would lie mostly on that
/// display, and the window server would move it there (verified: a window
/// belongs to the display holding most of it). Displays must therefore be
/// stacked (above/below each other), never side by side.
public enum DisplayArrangement {
    public struct Display: Equatable, Sendable {
        public let name: String
        public let frame: CGRect
        public init(name: String, frame: CGRect) { self.name = name; self.frame = frame }
    }

    /// Pairs of displays that share part of their vertical range, i.e. sit to
    /// the left or right of each other (displays never overlap).
    public static func sideBySide(_ displays: [Display]) -> [(Display, Display)] {
        var pairs: [(Display, Display)] = []
        for (i, a) in displays.enumerated() {
            for b in displays[(i + 1)...] {
                let overlap = min(a.frame.maxY, b.frame.maxY) - max(a.frame.minY, b.frame.minY)
                if overlap > 1 { pairs.append(a.frame.minX <= b.frame.minX ? (a, b) : (b, a)) }
            }
        }
        return pairs
    }

    public static func problem(displays: [Display], separateSpaces: Bool) -> String? {
        guard separateSpaces else {
            return "Paperi requires “Displays have separate Spaces”. Enable it in System Settings → Desktop & Dock → Mission Control, then log out and back in to apply the change."
        }
        guard let (left, right) = sideBySide(displays).first else { return nil }
        return "“\(left.name)” is to the left of “\(right.name)”. Windows that Paperi scrolls past "
            + "that edge would jump to the other display. Place your displays above or below "
            + "each other in Displays settings and Paperi resumes on its own."
    }

    @MainActor public static func currentProblem() -> String? {
        problem(displays: current(), separateSpaces: NSScreen.screensHaveSeparateSpaces)
    }

    /// Connected displays, in AppKit coordinates.
    @MainActor public static func current() -> [Display] {
        NSScreen.screens.map { Display(name: $0.localizedName, frame: $0.frame) }
    }
}
