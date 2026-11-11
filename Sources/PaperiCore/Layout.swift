import Foundation

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

/// One logical slot. Native tab membership must be established by the platform adapter,
/// never guessed from matching titles or frames.
public struct Slot: Codable, Equatable, Sendable {
    public var id: String
    public var members: [UInt32]
    public var activeMember: UInt32
    public init(id: String, members: [UInt32], activeMember: UInt32) {
        self.id = id; self.members = members; self.activeMember = activeMember
    }
}
public struct Column: Codable, Equatable, Sendable {
    public var slots: [Slot]
    public var width: Double
    public var weights: [Double]
    public init(slots: [Slot], width: Double, weights: [Double]? = nil) {
        self.slots = slots; self.width = width; self.weights = weights ?? slots.map { _ in 1 }
    }
}
public struct Placement: Codable, Equatable, Sendable {
    public var slotID: String
    public var windowID: UInt32
    public var frame: Rect
    public var virtualX: Double
}
public enum Direction: Sendable { case left, right, up, down }
public enum LayoutError: Error { case invalidGeometry, invalidMembership }

public struct Layout: Codable, Equatable, Sendable {
    public var columns: [Column]
    public var focused: String?
    public var offset: Double
    public init(columns: [Column] = [], focused: String? = nil, offset: Double = 0) {
        self.columns = columns; self.focused = focused; self.offset = offset
    }
    /// Widest a column may be: the canvas minus `edgeMargin` on both sides, so
    /// with neighbours on each side their edges and the margins stay visible.
    /// Falls back to the full canvas for margins that would leave under half.
    public static func maxColumnWidth(in canvas: Rect, edgeMargin: Double) -> Double {
        let capped = canvas.width - 2 * edgeMargin
        return edgeMargin.isFinite && edgeMargin >= 0 && capped >= canvas.width / 2 ? capped : canvas.width
    }

    public func index(of id: String) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.slots.firstIndex(where: { $0.id == id }) { return (c, r) }
        }
        return nil
    }
    public func validate() throws {
        var ids = Set<String>(); var windows = Set<UInt32>()
        guard offset.isFinite else { throw LayoutError.invalidGeometry }
        for column in columns {
            guard column.width.isFinite, column.width > 0, !column.slots.isEmpty,
                  column.weights.count == column.slots.count,
                  column.weights.allSatisfy({ $0.isFinite && $0 > 0 }),
                  column.weights.reduce(0, +).isFinite else { throw LayoutError.invalidGeometry }
            for slot in column.slots {
                guard ids.insert(slot.id).inserted, !slot.members.isEmpty,
                      slot.members.contains(slot.activeMember) else { throw LayoutError.invalidMembership }
                for member in slot.members {
                    guard member != 0, windows.insert(member).inserted else { throw LayoutError.invalidMembership }
                }
            }
        }
        if let focused, index(of: focused) == nil { throw LayoutError.invalidMembership }
    }
    /// nil signals a horizontal edge; the caller decides whether native Space navigation is allowed.
    public func neighbor(_ direction: Direction) -> String? {
        guard let focused, let i = index(of: focused) else { return nil }
        switch direction {
        case .left, .right:
            let c = i.column + (direction == .left ? -1 : 1)
            guard columns.indices.contains(c) else { return nil }
            return columns[c].slots[min(i.row, columns[c].slots.count - 1)].id
        case .up, .down:
            let r = i.row + (direction == .up ? -1 : 1)
            guard columns[i.column].slots.indices.contains(r) else { return nil }
            return columns[i.column].slots[r].id
        }
    }
    public mutating func swap(_ direction: Direction) {
        guard let focused, let i = index(of: focused) else { return }
        switch direction {
        case .left, .right:
            let c = i.column + (direction == .left ? -1 : 1)
            if columns.indices.contains(c) { columns.swapAt(i.column, c) }
        case .up, .down:
            let r = i.row + (direction == .up ? -1 : 1)
            if columns[i.column].slots.indices.contains(r) {
                columns[i.column].slots.swapAt(i.row, r)
                columns[i.column].weights.swapAt(i.row, r)
            }
        }
    }
    public mutating func slurp() {
        guard let focused, let i = index(of: focused), i.column > 0 else { return }
        let slot = columns[i.column].slots.remove(at: i.row)
        columns[i.column].weights.remove(at: i.row)
        columns[i.column - 1].slots.append(slot)
        columns[i.column - 1].weights.append(1)
        if columns[i.column].slots.isEmpty { columns.remove(at: i.column) }
    }
    public mutating func barf() {
        guard let focused, let i = index(of: focused), columns[i.column].slots.count > 1 else { return }
        let slot = columns[i.column].slots.remove(at: i.row)
        columns[i.column].weights.remove(at: i.row)
        columns.insert(Column(slots: [slot], width: columns[i.column].width), at: i.column + 1)
    }
    public mutating func center(in canvas: Rect, gap: Double = 8, edgeMargin: Double? = nil) throws {
        try validate()
        guard canvas.isValid, gap.isFinite, gap >= 0 else { throw LayoutError.invalidGeometry }
        guard let focused, let i = index(of: focused) else { return }
        let maximum = Self.maxColumnWidth(in: canvas, edgeMargin: edgeMargin ?? gap)
        let preceding = columns.prefix(i.column).reduce(0) { $0 + min($1.width, maximum) + gap }
        offset = (canvas.width - min(columns[i.column].width, maximum)) / 2 - preceding
    }
    /// Scrolls the minimum distance needed to show the whole focused column
    /// (PaperWM-style "ensure visible"); returns whether the offset changed.
    /// While further columns exist on a side, the focused column keeps
    /// `edgeMargin` (default: `gap`) from that canvas edge so it never sits flush
    /// against the neighbour's off-canvas sliver; a column too wide for both
    /// margins favours the left one.
    @discardableResult
    public mutating func reveal(in canvas: Rect, gap: Double = 8, edgeMargin: Double? = nil) throws -> Bool {
        try validate()
        let margin = edgeMargin ?? gap
        guard canvas.isValid, gap.isFinite, gap >= 0, margin.isFinite, margin >= 0 else { throw LayoutError.invalidGeometry }
        guard let focused, let i = index(of: focused) else { return false }
        let maximum = Self.maxColumnWidth(in: canvas, edgeMargin: margin)
        let preceding = columns.prefix(i.column).reduce(0) { $0 + min($1.width, maximum) + gap }
        let width = min(columns[i.column].width, maximum)
        let room = canvas.width - width
        let lowest = min(i.column > 0 ? margin : 0, room)
        let highest = max(lowest, room - (i.column < columns.count - 1 ? margin : 0))
        let left = preceding + offset
        let previous = offset
        if left < lowest { offset = lowest - preceding }
        else if left > highest { offset = highest - preceding }
        return offset != previous
    }
    /// Drop targets while dragging the window in slot `id`: every slot of the
    /// left and right neighbouring columns and the other rows of its own
    /// column. A region spans the on-canvas part of the slot's column (widened
    /// to at least `reach` at a canvas edge, so a neighbour showing only a
    /// sliver can still be hovered) and the slot's rows.
    public func swapTargets(slotID id: String, in canvas: Rect, gap: Double = 8, margin: Double = 1,
                            edgeMargin: Double? = nil, reach: Double = 24) throws -> [SwapTarget] {
        guard let source = index(of: id) else { throw LayoutError.invalidMembership }
        let frames = Dictionary(uniqueKeysWithValues: try placements(in: canvas, gap: gap, margin: margin, edgeMargin: edgeMargin)
            .map { ($0.slotID, $0.frame) })
        let right = canvas.x + canvas.width
        var result: [SwapTarget] = []
        for c in [source.column - 1, source.column, source.column + 1] where columns.indices.contains(c) {
            for slot in columns[c].slots where slot.id != id {
                guard let frame = frames[slot.id] else { continue }
                var lo = max(frame.x, canvas.x), hi = min(frame.x + frame.width, right)
                if lo <= canvas.x { hi = max(hi, canvas.x + reach) }
                if hi >= right { lo = min(lo, right - reach) }
                guard hi > lo else { continue }
                result.append(SwapTarget(slotID: slot.id, region: Rect(x: lo, y: frame.y, width: hi - lo, height: frame.height),
                                         sameColumn: c == source.column))
            }
        }
        return result
    }
    /// Swaps two slots (drag-to-swap). Two single-window columns swap as
    /// columns, so widths travel with their windows as with `swap left/right`;
    /// otherwise the windows exchange positions and take each other's size.
    @discardableResult public mutating func swapSlots(_ a: String, _ b: String) -> Bool {
        guard a != b, let i = index(of: a), let j = index(of: b) else { return false }
        if i.column != j.column, columns[i.column].slots.count == 1, columns[j.column].slots.count == 1 {
            columns.swapAt(i.column, j.column)
        } else {
            let slot = columns[i.column].slots[i.row]
            columns[i.column].slots[i.row] = columns[j.column].slots[j.row]
            columns[j.column].slots[j.row] = slot
        }
        return true
    }
    /// Applies a drag-and-drop of slot `source` onto slot `target`. Stacking
    /// splits the target's height between it and the dropped window; a new
    /// column takes the dragged window's column width. Columns emptied by the
    /// move are removed. Focus is unchanged.
    @discardableResult public mutating func drop(_ source: String, on target: String, action: DropAction) -> Bool {
        guard source != target, let s = index(of: source), index(of: target) != nil else { return false }
        if action == .swap { return swapSlots(source, target) }
        if (action == .newColumnLeft || action == .newColumnRight), columns[s.column].slots.count < 2 { return false }
        let width = columns[s.column].width
        let slot = columns[s.column].slots.remove(at: s.row)
        columns[s.column].weights.remove(at: s.row)
        if columns[s.column].slots.isEmpty { columns.remove(at: s.column) }
        let t = index(of: target)!
        switch action {
        case .stackAbove, .stackBelow:
            let half = columns[t.column].weights[t.row] / 2
            columns[t.column].weights[t.row] = half
            let row = t.row + (action == .stackBelow ? 1 : 0)
            columns[t.column].slots.insert(slot, at: row)
            columns[t.column].weights.insert(half, at: row)
        case .newColumnLeft, .newColumnRight:
            columns.insert(Column(slots: [slot], width: width), at: t.column + (action == .newColumnRight ? 1 : 0))
        case .swap: break
        }
        return true
    }
    public func placements(in canvas: Rect, gap: Double = 8, margin: Double = 1,
                           edgeMargin: Double? = nil) throws -> [Placement] {
        try validate()
        guard canvas.isValid, gap.isFinite, gap >= 0, margin.isFinite, margin >= 0,
              margin * 2 < canvas.width else { throw LayoutError.invalidGeometry }
        let maximum = Self.maxColumnWidth(in: canvas, edgeMargin: edgeMargin ?? gap)
        var x = canvas.x + offset; var result: [Placement] = []
        for column in columns {
            let width = min(column.width, maximum)
            let physicalX = max(canvas.x + margin - width, min(x, canvas.x + canvas.width - margin))
            // Reduce excessive gaps rather than creating zero/negative stacked heights.
            let verticalGap = min(gap, canvas.height / Double(column.slots.count * 2))
            let available = canvas.height - verticalGap * Double(column.slots.count - 1)
            let total = column.weights.reduce(0, +)
            var y = canvas.y
            for (row, slot) in column.slots.enumerated() {
                let height = available * column.weights[row] / total
                result.append(Placement(slotID: slot.id, windowID: slot.activeMember,
                                        frame: Rect(x: physicalX, y: y, width: width, height: height), virtualX: x))
                y += height + verticalGap
            }
            x += width + gap
        }
        return result
    }
}

/// What releasing a dragged window over a `SwapTarget` does.
public enum DropAction: String, Equatable, Sendable {
    /// Exchange the two windows.
    case swap
    /// Join the target's column directly above / below it, splitting its height.
    case stackAbove, stackBelow
    /// Leave the shared column for a new column on its left / right.
    case newColumnLeft, newColumnRight
}

public struct SwapTarget: Equatable, Sendable {
    public var slotID: String
    /// Screen area (top-left origin) that arms the drop and is highlighted.
    public var region: Rect
    /// The target is stacked in the dragged window's own column.
    public var sameColumn: Bool
    /// Fraction of the region at each end that arms a stack or new-column drop.
    public static let edgeZone = 0.25
    public init(slotID: String, region: Rect, sameColumn: Bool = false) {
        self.slotID = slotID; self.region = region; self.sameColumn = sameColumn
    }
    public func contains(x: Double, y: Double) -> Bool {
        x >= region.x && x < region.x + region.width && y >= region.y && y < region.y + region.height
    }
    /// The drop armed at a point: for a window in another column the top and
    /// bottom quarters stack the dragged window above or below it; for one in
    /// the dragged window's own stack the left and right quarters move the
    /// dragged window out into a new column on that side. The middle swaps.
    public func action(x: Double, y: Double) -> DropAction? {
        guard contains(x: x, y: y) else { return nil }
        if sameColumn {
            let f = (x - region.x) / region.width
            return f < Self.edgeZone ? .newColumnLeft : f >= 1 - Self.edgeZone ? .newColumnRight : .swap
        }
        let f = (y - region.y) / region.height
        return f < Self.edgeZone ? .stackAbove : f >= 1 - Self.edgeZone ? .stackBelow : .swap
    }
}

public struct Section: Equatable, Sendable {
    public var slotIDs: [String]
    public var anchor: Double
}
public enum Paging {
    /// Stable snapshot for the duration of a drag. Sections keep whole columns together.
    public static func sections(_ layout: Layout, viewportWidth: Double, gap: Double = 8) throws -> [Section] {
        try layout.validate()
        guard viewportWidth.isFinite, viewportWidth > 0, gap.isFinite, gap >= 0 else { throw LayoutError.invalidGeometry }
        var result: [Section] = []; var ids: [String] = []; var used = 0.0
        func flush() {
            if !ids.isEmpty { result.append(Section(slotIDs: ids, anchor: -Double(result.count) * viewportWidth)) }
            ids = []; used = 0
        }
        let maximum = Layout.maxColumnWidth(in: Rect(x: 0, y: 0, width: viewportWidth, height: 1), edgeMargin: gap)
        for column in layout.columns {
            let width = min(column.width, maximum)
            let addition = width + (ids.isEmpty ? 0 : gap)
            if used + addition > viewportWidth && !ids.isEmpty { flush() }
            used += width + (ids.isEmpty ? 0 : gap)
            ids.append(contentsOf: column.slots.map(\.id))
        }
        flush(); return result
    }
    public static func destination(current: Int, count: Int, translation: Double,
                                   velocity: Double, viewportWidth: Double) -> Int {
        guard count > 0, viewportWidth.isFinite, viewportWidth > 0,
              translation.isFinite, velocity.isFinite else { return current }
        let start = min(max(0, current), count - 1)
        let pages: Int
        if abs(translation) >= viewportWidth * 0.35 {
            pages = Int(min(Double(count), max(1, (abs(translation) / viewportWidth).rounded()))) * (translation < 0 ? 1 : -1)
        } else if abs(velocity) >= 600 { pages = velocity < 0 ? 1 : -1 }
        else { pages = 0 }
        return min(max(0, start + pages), count - 1)
    }
}
