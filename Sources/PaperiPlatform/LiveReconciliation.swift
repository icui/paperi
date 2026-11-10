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
    /// (PaperWM-style). When that sliver would spill onto a neighbouring display,
    /// the window server would reassign it to that display's Space, so it is
    /// parked below its own display instead (or left as a sliver if a display is
    /// below too). The same applies to a partly visible column that lies mostly
    /// on a neighbouring display: the window server assigns a window to the
    /// display holding most of it, so the peek is given up to keep the window.
    static func park(_ frame: Rect, canvas: Rect, display: CGRect, otherDisplays: [CGRect], margin: Double = 1) -> Rect {
        func rect(_ r: Rect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        func area(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            return i.isNull ? 0 : i.width * i.height
        }
        let own = area(display, rect(frame))
        let foreign = otherDisplays.map { area($0, rect(frame)) }.max() ?? 0
        let hiddenLeft = frame.x + frame.width <= canvas.x + margin + 0.5
        let hiddenRight = frame.x >= canvas.x + canvas.width - margin - 0.5
        guard foreign >= 1, hiddenLeft || hiddenRight || foreign >= own else { return frame }
        // Partly visible: park on the side it sticks out of.
        let left = hiddenLeft || (!hiddenRight && frame.x + frame.width / 2 < canvas.x + canvas.width / 2)
        let below = Rect(x: left ? canvas.x : canvas.x + canvas.width - frame.width,
                         y: Double(display.maxY) - margin, width: frame.width, height: frame.height)
        if !otherDisplays.contains(where: { intersects($0, rect(below)) }) { return below }
        return frame
    }
}
