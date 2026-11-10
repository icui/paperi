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

    /// `frame` moved (and shrunk if needed) to lie inside `canvas`.
    static func fit(_ frame: Rect, into canvas: Rect) -> Rect {
        let width = min(frame.width, canvas.width), height = min(frame.height, canvas.height)
        return Rect(x: min(max(frame.x, canvas.x), canvas.x + canvas.width - width),
                    y: min(max(frame.y, canvas.y), canvas.y + canvas.height - height), width: width, height: height)
    }
}
