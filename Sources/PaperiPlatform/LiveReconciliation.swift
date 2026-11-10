import CoreGraphics
import PaperiCore

/// Pure helpers for the live manager. No OS effects run here.
enum LiveReconciliation {
    /// Removes destroyed physical members from existing containers. Containers
    /// lose a member without moving; a destroyed active representative is
    /// replaced by the first survivor until fresh tab evidence selects the real
    /// one. Fully destroyed containers disappear.
    static func partitions(removing destroyed: Set<UInt32>, from slots: [Slot]) -> [NativeTabPartition] {
        slots.compactMap { slot in
            let survivors = slot.members.filter { !destroyed.contains($0) }
            guard let first = survivors.first else { return nil }
            return NativeTabPartition(members: survivors,
                                      active: survivors.contains(slot.activeMember) ? slot.activeMember : first)
        }
    }

    /// Identity partitions for every container whose members are not owned by
    /// `excluded`; used so one app's tab reconciliation keeps other apps' slots.
    static func identityPartitions(_ slots: [Slot], excluding excluded: Set<UInt32>) -> [NativeTabPartition] {
        slots.filter { Set($0.members).isDisjoint(with: excluded) }
            .map { NativeTabPartition(members: $0.members, active: $0.activeMember) }
    }

    static func intersects(_ a: CGRect, _ b: CGRect, minimumArea: CGFloat = 1) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width * i.height >= minimumArea
    }

    /// A column scrolled out of view is kept as a sliver at the canvas edge
    /// (PaperWM-style), and a partly visible column peeks in. The window server
    /// assigns a window to the display holding most of it, so when a sliver or
    /// peek would lie mostly on a neighbouring display it is slid back toward
    /// its own display until just over half of it stays there. That part sits
    /// under the neighbouring visible column, so on screen it still reads as an
    /// edge sliver or peek; the part over the neighbour is not drawn there
    /// ("Displays have separate Spaces"). Parking below the display instead
    /// left a title-bar strip visible, since macOS keeps title bars on screen.
    static func park(_ frame: Rect, display: CGRect, otherDisplays: [CGRect]) -> Rect {
        func rect(_ r: Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        func area(_ a: CGRect, _ b: CGRect) -> Double {
            let i = a.intersection(b)
            return i.isNull ? 0 : Double(i.width * i.height)
        }
        let own = area(display, rect(frame))
        let foreign = otherDisplays.map { area($0, rect(frame)) }.max() ?? 0
        guard foreign >= 1, foreign >= own else { return frame }
        // Keep `keep` points more of the window on its own display than off it.
        let keep = 16.0
        var moved = frame
        if frame.x + frame.width / 2 > Double(display.midX) {
            moved.x = Double(display.maxX) - frame.width / 2 - keep
        } else {
            moved.x = Double(display.minX) - frame.width / 2 + keep
        }
        return moved
    }
}
