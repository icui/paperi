import CoreGraphics
import PaperiCore

/// Pure helpers for the live manager. No OS effects run here.
enum LiveReconciliation {
    /// Complete physical targets: ordinary placements plus off-screen adjustments.
    static func focusTargets(_ placements: [Placement], canvas: Rect, screenInset: Double) -> [UInt32: Rect] {
        let frames = placements.map { (window: $0.windowID, frame: $0.frame) }
        return Dictionary(frames.map { ($0.window, $0.frame) }, uniquingKeysWith: { a, _ in a })
            .merging(tuck(frames, canvas: canvas, screenInset: screenInset)) { _, tucked in tucked }
    }

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

    /// `frame` moved (and shrunk if needed) to lie inside `canvas`.
    static func fit(_ frame: Rect, into canvas: Rect) -> Rect {
        let width = min(frame.width, canvas.width), height = min(frame.height, canvas.height)
        return Rect(x: min(max(frame.x, canvas.x), canvas.x + canvas.width - width),
                    y: min(max(frame.y, canvas.y), canvas.y + canvas.height - height), width: width, height: height)
    }

    /// Windows past each canvas edge, nearest to the visible area first
    /// (desired top-to-bottom order). Fully visible columns never overlap.
    static func edgeGroups(_ frames: [(window: UInt32, frame: Rect)], canvas: Rect) -> [[UInt32]] {
        let left = frames.filter { $0.frame.x < canvas.x - 0.5 }
            .sorted { $0.frame.x + $0.frame.width > $1.frame.x + $1.frame.width }.map(\.window)
        let right = frames.filter { $0.frame.x + $0.frame.width > canvas.x + canvas.width + 0.5 }
            .sorted { $0.frame.x < $1.frame.x }.map(\.window)
        return [left, right].filter { $0.count > 1 }
    }

    /// Columns past the same edge overlap there (macOS keeps part of every
    /// window on screen), so which one shows would depend on window order,
    /// which clicks and app activation change. Only the column nearest the
    /// visible area keeps its sliver or peek; those beyond it are pushed to the
    /// screen edge with 1 pt left on screen. Returns their new frames.
    static func tuck(_ frames: [(window: UInt32, frame: Rect)], canvas: Rect, screenInset: Double) -> [UInt32: Rect] {
        let byID = Dictionary(frames.map { ($0.window, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let groups = edgeGroups(frames, canvas: canvas)
        var result: [UInt32: Rect] = [:]
        for (index, group) in groups.enumerated() {
            let left = byID[group[0]].map { $0.x < canvas.x } ?? (index == 0)
            for wid in group.dropFirst() {
                guard var frame = byID[wid] else { continue }
                frame.x = left ? canvas.x - screenInset - frame.width + 1 : canvas.x + canvas.width + screenInset - 1
                result[wid] = frame
            }
        }
        return result
    }
}
