import CoreGraphics
import PaperiCore

/// Pure helpers for the live manager. No OS effects run here.
enum LiveReconciliation {
    /// A small excursion away from the requested edge, returning exactly to
    /// the layout frame. Position only: window dimensions and focus stay fixed.
    static func edgeBounce(_ frame: Rect, toward direction: Direction, progress: Double) -> Rect {
        guard progress.isFinite, progress > 0, progress < 1 else { return frame }
        let pulse = sin(.pi * progress)
        let distance = 24 * pulse * pulse
        var result = frame
        switch direction {
        case .left: result.x += distance
        case .right: result.x -= distance
        case .up: result.y += distance
        case .down: result.y -= distance
        }
        return result
    }

    /// Complete physical targets: ordinary placements plus off-screen adjustments.
    static func focusTargets(_ placements: [Placement], canvas: Rect, screenInset: Double) -> [UInt32: Rect] {
        Dictionary(placements.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
            .merging(tuck(edgeItems(placements), canvas: canvas, screenInset: screenInset)) { _, tucked in tucked }
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

    /// One window for `edgeGroups`/`tuck`: `column` identifies its column
    /// (e.g. `Placement.virtualX`), since columns clamped at an edge can share x.
    typealias EdgeItem = (window: UInt32, frame: Rect, column: Double)

    static func edgeItems(_ placements: [Placement]) -> [EdgeItem] {
        placements.map { ($0.windowID, $0.frame, $0.virtualX) }
    }

    /// Columns past each canvas edge, nearest to the visible area first
    /// (desired top-to-bottom order), each listing its windows top to bottom.
    /// Only edges with more than one column are listed: fully visible columns
    /// never overlap.
    static func edgeGroups(_ items: [EdgeItem], canvas: Rect) -> [[[UInt32]]] {
        func columns(_ side: [EdgeItem], left: Bool) -> [[UInt32]] {
            let byColumn = Dictionary(grouping: side, by: \.column)
            return byColumn.keys.sorted(by: left ? (>) : (<)).map { key in
                byColumn[key]!.sorted { $0.frame.y < $1.frame.y }.map(\.window)
            }
        }
        let left = columns(items.filter { $0.frame.x < canvas.x - 0.5 }, left: true)
        let right = columns(items.filter { $0.frame.x + $0.frame.width > canvas.x + canvas.width + 0.5 }, left: false)
        return [left, right].filter { $0.count > 1 }
    }

    /// Columns past the same edge overlap there (macOS keeps part of every
    /// window on screen), so which one shows would depend on window order,
    /// which clicks and app activation change. Only the column nearest the
    /// visible area keeps its sliver or peek, with every window of a stacked
    /// column; those beyond it are pushed to the screen edge with 1 pt left on
    /// screen. Returns their new frames.
    static func tuck(_ items: [EdgeItem], canvas: Rect, screenInset: Double) -> [UInt32: Rect] {
        let byID = Dictionary(items.map { ($0.window, $0.frame) }, uniquingKeysWith: { a, _ in a })
        var result: [UInt32: Rect] = [:]
        for (index, group) in edgeGroups(items, canvas: canvas).enumerated() {
            let left = byID[group[0][0]].map { $0.x < canvas.x } ?? (index == 0)
            for wid in group.dropFirst().joined() {
                guard var frame = byID[wid] else { continue }
                frame.x = left ? canvas.x - screenInset - frame.width + 1 : canvas.x + canvas.width + screenInset - 1
                result[wid] = frame
            }
        }
        return result
    }

    // MARK: swipe

    /// Positions `progress` (0…1) of the way from `starts` to `ends`; sizes
    /// stay at the start. Windows missing from either side keep their start.
    ///
    /// Every image moves at the same speed: the strip's, set by the longest
    /// travel. A window tucked at a canvas edge at one end travels less, so it
    /// moves only for its share of the gesture: leaving the tuck at the end
    /// (when it enters view) or reaching it early (when it leaves view), as if
    /// it were part of the rigid strip clamped at the edge.
    static func interpolate(_ starts: [UInt32: Rect], _ ends: [UInt32: Rect], progress: Double,
                            canvas: Rect? = nil) -> [UInt32: Rect] {
        let t = min(1, max(0, progress.isFinite ? progress : 0))
        func distance(_ a: Rect, _ b: Rect) -> Double { hypot(b.x - a.x, b.y - a.y) }
        func visible(_ frame: Rect, _ canvas: Rect) -> Double {
            max(0, min(frame.x + frame.width, canvas.x + canvas.width) - max(frame.x, canvas.x))
        }
        let travel = starts.compactMap { id, start in ends[id].map { distance(start, $0) } }.max() ?? 0
        return starts.reduce(into: [:]) { result, item in
            var frame = item.value
            if let end = ends[item.key] {
                let own = distance(frame, end)
                var u = t
                // Within a couple of points of the strip's travel is the strip.
                if own > 0, own < travel - 2 {
                    let share = own / travel
                    let entering = canvas.map { visible(frame, $0) < visible(end, $0) } ?? false
                    u = min(1, max(0, entering ? (t - (1 - share)) / share : t / share))
                }
                frame.x += (end.x - frame.x) * u
                frame.y += (end.y - frame.y) * u
            }
            result[item.key] = frame
        }
    }

    /// Hand-off check after the real windows were moved under the snapshot
    /// overlay: `settled` once every window read the same frame twice in a
    /// row; `landing` are the observed frames the images should finish on
    /// (macOS or the app may not put a window exactly on its target).
    static func handoff(previous: [UInt32: Rect], current: [UInt32: Rect], targets: [UInt32: Rect],
                        tolerance: Double = 0.5) -> (settled: Bool, landing: [UInt32: Rect], maxDeviation: Double) {
        var settled = true, deviation = 0.0, landing: [UInt32: Rect] = [:]
        for (wid, target) in targets {
            guard let now = current[wid], now.isValid else { settled = false; landing[wid] = target; continue }
            if let before = previous[wid] {
                if abs(before.x - now.x) > tolerance || abs(before.y - now.y) > tolerance || abs(before.width - now.width) > tolerance || abs(before.height - now.height) > tolerance { settled = false }
            } else { settled = false }
            landing[wid] = Rect(x: now.x, y: now.y, width: target.width, height: target.height)
            deviation = max(deviation, abs(now.x - target.x), abs(now.y - target.y))
        }
        return (settled, landing, deviation)
    }
}
