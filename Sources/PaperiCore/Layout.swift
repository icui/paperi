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
    public mutating func center(in canvas: Rect, gap: Double = 8) throws {
        try validate()
        guard canvas.isValid, gap.isFinite, gap >= 0 else { throw LayoutError.invalidGeometry }
        guard let focused, let i = index(of: focused) else { return }
        let preceding = columns.prefix(i.column).reduce(0) { $0 + min($1.width, canvas.width) + gap }
        offset = (canvas.width - min(columns[i.column].width, canvas.width)) / 2 - preceding
    }
    public func placements(in canvas: Rect, gap: Double = 8, margin: Double = 1) throws -> [Placement] {
        try validate()
        guard canvas.isValid, gap.isFinite, gap >= 0, margin.isFinite, margin >= 0,
              margin * 2 < canvas.width else { throw LayoutError.invalidGeometry }
        var x = canvas.x + offset; var result: [Placement] = []
        for column in columns {
            let width = min(column.width, canvas.width)
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
        for column in layout.columns {
            let width = min(column.width, viewportWidth)
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
