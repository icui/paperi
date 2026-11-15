import Foundation

/// A boundary that can be dragged to resize windows: usually the gap
/// between two neighbouring windows, resizing both.
public enum Divider: Equatable, Hashable, Sendable {
    /// Between column `n` and column `n + 1`; dragging moves it horizontally.
    case columns(Int)
    /// Between row `row` and row `row + 1` of `column`; dragging moves it vertically.
    case rows(column: Int, row: Int)
    /// The right edge of `column` alone: only that column resizes, its left
    /// edge stays put and later columns travel with the right one. Its
    /// position is the centre of the gap-wide band just right of the edge,
    /// like a gap's.
    case columnEdge(Int)

    public var isVertical: Bool { if case .rows = self { return false } else { return true } }
}

public struct DividerRegion: Equatable, Sendable {
    public var divider: Divider
    /// The gap on screen (top-left origin), clipped to the canvas.
    public var gap: Rect
    /// Screen coordinate of the gap's centre along the drag axis (x for
    /// columns, y for rows); `Layout.moveDivider` takes the same coordinate.
    public var position: Double
    public init(divider: Divider, gap: Rect, position: Double) {
        self.divider = divider; self.gap = gap; self.position = position
    }
    /// Row boundaries grab across their full width so stacked windows always
    /// resize together. Column boundaries use a centred `length` segment.
    /// Both are widened across the gap to at least `hitWidth`.
    public func hitRegion(hitWidth: Double, length: Double) -> Rect {
        if divider.isVertical {
            let w = max(gap.width, hitWidth), h = min(gap.height, length)
            return Rect(x: position - w / 2, y: gap.y + (gap.height - h) / 2, width: w, height: h)
        }
        let h = max(gap.height, hitWidth), w = gap.width
        return Rect(x: gap.x + (gap.width - w) / 2, y: position - h / 2, width: w, height: h)
    }
    public func contains(x: Double, y: Double, hitWidth: Double, length: Double) -> Bool {
        let r = hitRegion(hitWidth: hitWidth, length: length)
        return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
    }
}

extension Layout {
    /// The edge of slot `id`'s window that a resize along one axis moves:
    /// horizontally its column's right edge; vertically, for a stacked
    /// window only, the gap below it, or above it for the bottom window.
    public func resizeEdge(of id: String, vertical: Bool) -> Divider? {
        guard let at = index(of: id) else { return nil }
        guard vertical else { return .columnEdge(at.column) }
        let rows = columns[at.column].slots.count
        guard rows > 1 else { return nil }
        return .rows(column: at.column, row: at.row + 1 < rows ? at.row : at.row - 1)
    }

    /// `divider` as laid out now, or nil if it is not on screen: a gap from
    /// `dividers`, or for a column edge the gap-wide band outside it.
    public func region(of divider: Divider, in canvas: Rect, gap: Double = 8,
                       edgeMargin: Double? = nil) throws -> DividerRegion? {
        guard case .columnEdge(let c) = divider else {
            return try dividers(in: canvas, gap: gap, edgeMargin: edgeMargin).first { $0.divider == divider }
        }
        guard columns.indices.contains(c),
              let first = try placements(in: canvas, gap: gap, edgeMargin: edgeMargin)
                .first(where: { $0.slotID == columns[c].slots[0].id }) else { return nil }
        let lo = first.virtualX + first.frame.width
        // An edge on the canvas's right edge may land a rounding error past it.
        guard lo + gap >= canvas.x, lo <= canvas.x + canvas.width + 1 else { return nil }
        return DividerRegion(divider: divider, gap: Rect(x: lo, y: canvas.y, width: gap, height: canvas.height),
                             position: lo + gap / 2)
    }

    /// The draggable gaps fully on canvas: between adjacent columns whose
    /// shared gap is on screen, and between stacked rows of a column with
    /// at least `minimumSpan` of its width on screen. Gaps beside a parked
    /// column's sliver are excluded, as are both edges of the strip.
    public func dividers(in canvas: Rect, gap: Double = 8, edgeMargin: Double? = nil,
                         minimumSpan: Double = 40) throws -> [DividerRegion] {
        let placements = try self.placements(in: canvas, gap: gap, edgeMargin: edgeMargin)
        let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.slotID, $0) })
        let left = canvas.x, right = canvas.x + canvas.width
        var result: [DividerRegion] = []
        for c in columns.indices {
            guard let first = frames[columns[c].slots[0].id] else { continue }
            let frame = first.frame
            // Physical and virtual x agree only while the column is not parked.
            let onCanvas = first.virtualX == frame.x
            if c + 1 < columns.count, onCanvas, let next = frames[columns[c + 1].slots[0].id],
               next.virtualX == next.frame.x {
                let lo = frame.x + frame.width, hi = next.frame.x
                if hi >= lo, lo >= left, hi <= right, frame.x + frame.width - max(frame.x, left) >= minimumSpan,
                   min(next.frame.x + next.frame.width, right) - next.frame.x >= minimumSpan {
                    result.append(DividerRegion(divider: .columns(c),
                                                gap: Rect(x: lo, y: canvas.y, width: hi - lo, height: canvas.height),
                                                position: (lo + hi) / 2))
                }
            }
            guard columns[c].slots.count > 1 else { continue }
            let lo = max(frame.x, left), hi = min(frame.x + frame.width, right)
            guard hi - lo >= minimumSpan else { continue }
            for r in 0 ..< columns[c].slots.count - 1 {
                guard let above = frames[columns[c].slots[r].id]?.frame,
                      let below = frames[columns[c].slots[r + 1].id]?.frame else { continue }
                let top = above.y + above.height, bottom = below.y
                result.append(DividerRegion(divider: .rows(column: c, row: r),
                                            gap: Rect(x: lo, y: top, width: hi - lo, height: max(0, bottom - top)),
                                            position: (top + bottom) / 2))
            }
        }
        return result
    }

    /// Moves a divider so its gap is centred on `position` (a screen x for a
    /// column divider, y for a row divider). The windows on either side
    /// resize while their outer edges stay put, so the rest of the strip does
    /// not move.
    /// - The shrinking side stops at its floor, and so does the gap.
    /// - The growing side stops at its cap and then travels with the gap
    ///   while the other side keeps shrinking. A column moves whole: the
    ///   left one by scrolling the strip (carrying earlier columns), the
    ///   right one by pulling later columns along. A column's height is
    ///   fixed, so a capped row instead passes the growth on to the rows
    ///   beyond it, nearest first, and so moves with the gap.
    /// A column edge moves alone: see `Divider.columnEdge`. Past the
    /// canvas's right edge it scrolls the strip instead, and the last column,
    /// when against that edge, stays there as it shrinks. Either scroll moves
    /// the edge's screen position; a drag that keeps re-targeting it
    /// compensates by the change in `offset`.
    /// A window's floor is `minimum`, or its entry in `minimums` (slot ID →
    /// smallest size along the drag axis, e.g. an app's minimum window size)
    /// if larger; its cap is its entry in `maximums` (an app's maximum size),
    /// and for columns at most `Layout.maxColumnWidth`. A window already past
    /// either limit is never resized towards it. Returns whether the layout
    /// changed.
    @discardableResult
    public mutating func moveDivider(_ divider: Divider, to position: Double, in canvas: Rect, gap: Double = 8,
                                     edgeMargin: Double? = nil, minimum: Double = 120,
                                     minimums: [String: Double] = [:], maximums: [String: Double] = [:]) throws -> Bool {
        guard position.isFinite, minimum.isFinite, minimum >= 0 else { throw LayoutError.invalidGeometry }
        let placements = try self.placements(in: canvas, gap: gap, edgeMargin: edgeMargin)
        let frames = Dictionary(uniqueKeysWithValues: placements.map { ($0.slotID, $0) })
        let before = self
        func floor(_ slots: [Slot], _ size: Double) -> Double {
            min(size, slots.map { max(minimum, minimums[$0.id] ?? 0) }.max()!)
        }
        func cap(_ slots: [Slot], _ size: Double, limit: Double = .infinity) -> Double {
            max(size, min(limit, slots.map { maximums[$0.id] ?? .infinity }.min()!))
        }
        switch divider {
        case .columns(let c):
            guard c >= 0, c + 1 < columns.count,
                  let a = frames[columns[c].slots[0].id], let b = frames[columns[c + 1].slots[0].id] else { return false }
            let maximum = Self.maxColumnWidth(in: canvas, edgeMargin: edgeMargin ?? gap)
            let floorA = floor(columns[c].slots, a.frame.width), floorB = floor(columns[c + 1].slots, b.frame.width)
            let capA = cap(columns[c].slots, a.frame.width, limit: maximum)
            let capB = cap(columns[c + 1].slots, b.frame.width, limit: maximum)
            let left = a.virtualX, right = b.virtualX + b.frame.width
            let lower = left + gap / 2 + floorA, upper = right - gap / 2 - floorB
            guard lower <= upper else { return false }
            let centre = min(upper, max(lower, position))
            var widthA = centre - gap / 2 - left, widthB = right - centre - gap / 2
            if widthA > capA {
                // The left column travels with the gap: scroll the strip.
                offset += widthA - capA; widthA = capA
            }
            // The right column travels with the gap; later columns follow.
            if widthB > capB { widthB = capB }
            columns[c].width = widthA
            columns[c + 1].width = widthB
        case .columnEdge(let c):
            guard columns.indices.contains(c), let a = frames[columns[c].slots[0].id] else { return false }
            let margin = edgeMargin ?? gap
            let maximum = Self.maxColumnWidth(in: canvas, edgeMargin: margin)
            let lower = floor(columns[c].slots, a.frame.width)
            let upper = cap(columns[c].slots, a.frame.width, limit: maximum)
            let left = a.virtualX, right = left + a.frame.width
            let width = min(upper, max(lower, position - gap / 2 - left))
            columns[c].width = width
            // The canvas edge (less the margin `reveal` keeps while columns
            // follow) is a wall: growth past it scrolls the strip, so the
            // window grows leftward. An edge already past it stays put.
            let last = c + 1 == columns.count
            let edge = canvas.x + canvas.width - (last ? 0 : margin)
            let wall = max(right, edge)
            if left + width > wall { offset -= left + width - wall }
            // The last column keeps to the wall as it shrinks: nothing
            // follows its edge, so the strip scrolls the columns before it
            // in, until the strip's start reaches the canvas's left edge.
            else if last, width < a.frame.width, right >= edge - 0.5 {
                offset = min(offset + right - (left + width), max(offset, 0))
            }
        case .rows(let c, let r):
            guard columns.indices.contains(c), r >= 0, r + 1 < columns[c].slots.count else { return false }
            let slots = columns[c].slots
            let rows = slots.compactMap { frames[$0.id]?.frame }
            guard rows.count == slots.count else { return false }
            var heights = rows.map(\.height)
            let floors = slots.indices.map { floor([slots[$0]], heights[$0]) }
            let caps = slots.indices.map { cap([slots[$0]], heights[$0]) }
            let spacing = rows[r + 1].y - (rows[r].y + rows[r].height)
            let delta = position - spacing / 2 - rows[r].y - heights[r]
            let shrinking = delta > 0 ? r + 1 : r
            let taken = min(abs(delta), heights[shrinking] - floors[shrinking])
            heights[shrinking] -= taken
            // Grow the near side, passing growth on past capped rows.
            var remaining = taken
            for i in (delta > 0 ? Array((0 ... r).reversed()) : Array(r + 1 ..< slots.count)) where remaining > 0 {
                let given = min(remaining, caps[i] - heights[i])
                heights[i] += given; remaining -= given
            }
            heights[shrinking] += remaining
            let scale = columns[c].weights.reduce(0, +) / heights.reduce(0, +)
            columns[c].weights = heights.map { $0 * scale }
        }
        try validate()
        return self != before
    }
}
