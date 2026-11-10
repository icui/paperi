import Foundation

extension Layout {
    /// Resize by a fraction of the usable canvas; positive values grow the column.
    /// The result never exceeds `Layout.maxColumnWidth` for `edgeMargin`.
    public mutating func resizeWidth(by fraction: Double, in canvas: Rect, edgeMargin: Double = 8) throws {
        try validate()
        guard canvas.isValid, fraction.isFinite else { throw LayoutError.invalidGeometry }
        guard let focused, let i = index(of: focused) else { return }
        let delta = canvas.width * fraction
        guard delta.isFinite else { throw LayoutError.invalidGeometry }
        let maximum = Self.maxColumnWidth(in: canvas, edgeMargin: edgeMargin)
        columns[i.column].width = min(maximum, max(min(1, maximum), min(columns[i.column].width, maximum) + delta))
    }

    /// Redistribute the remaining stack proportionally, retaining positive row heights.
    public mutating func resizeHeight(by fraction: Double, in canvas: Rect, gap: Double = 8) throws {
        let frames = try placements(in: canvas, gap: gap)
        guard fraction.isFinite, (canvas.height * fraction).isFinite else { throw LayoutError.invalidGeometry }
        guard let focused, let i = index(of: focused), columns[i.column].slots.count > 1 else { return }
        let column = columns[i.column]
        let heights = column.slots.map { slot in frames.first { $0.slotID == slot.id }!.frame.height }
        let available = heights.reduce(0, +)
        let minimum = min(1, available / Double(heights.count * 2))
        let target = min(available - minimum * Double(heights.count - 1), max(minimum, heights[i.row] + canvas.height * fraction))
        let remainder = available - target
        // Reserve a minimum for every sibling before distributing its share.
        let distributable = max(0, remainder - minimum * Double(heights.count - 1))
        let largest = column.weights.enumerated().filter { $0.offset != i.row }.map(\.element).max()!
        let normalized = column.weights.enumerated().map { $0.offset == i.row ? 0 : $0.element / largest }
        let total = normalized.reduce(0, +)
        columns[i.column].weights = heights.indices.map { row in
            row == i.row ? target : minimum + distributable * normalized[row] / total
        }
    }

    /// Place the left and focused columns across two equal halves, separated by one gap.
    /// Edges with further columns beyond them keep `edgeMargin` (default: `gap`),
    /// matching `reveal`, so the next refresh does not shift the pair.
    public mutating func split(in canvas: Rect, gap: Double = 8, edgeMargin: Double? = nil) throws {
        try validate()
        let margin = edgeMargin ?? gap
        let maximum = Self.maxColumnWidth(in: canvas, edgeMargin: margin)
        guard canvas.isValid, gap.isFinite, gap >= 0, margin.isFinite, margin >= 0 else { throw LayoutError.invalidGeometry }
        guard let focused, let i = index(of: focused), i.column > 0 else { return }
        let leading = i.column > 1 ? margin : 0
        let trailing = i.column < columns.count - 1 ? margin : 0
        let width = (canvas.width - gap - leading - trailing) / 2
        guard width > 0 else { throw LayoutError.invalidGeometry }
        columns[i.column - 1].width = width
        columns[i.column].width = width
        offset = leading - columns.prefix(i.column - 1).reduce(0) { $0 + min($1.width, maximum) + gap }
    }
}

/// Floating documents remain logical slots, including all confirmed native-tab members.
/// The caller supplies current classification; excluded or pending windows cannot toggle.
public struct LayoutState: Codable, Equatable, Sendable {
    public var tiled: Layout
    public private(set) var floating: [Column]

    public init(tiled: Layout = Layout(), floating: [Column] = []) {
        self.tiled = tiled
        self.floating = floating
    }

    public func validate() throws {
        try tiled.validate()
        guard floating.allSatisfy({ $0.slots.count == 1 }) else { throw LayoutError.invalidMembership }
        try Layout(columns: tiled.columns + floating).validate()
    }

    @discardableResult
    public mutating func toggleFloating(slotID: String, classification: Classification) throws -> Bool {
        try validate()
        guard classification.eligibility == .tiled || classification.eligibility == .floating else { return false }
        if let i = tiled.index(of: slotID) {
            let slot = tiled.columns[i.column].slots.remove(at: i.row)
            tiled.columns[i.column].weights.remove(at: i.row)
            floating.append(Column(slots: [slot], width: tiled.columns[i.column].width))
            if tiled.columns[i.column].slots.isEmpty { tiled.columns.remove(at: i.column) }
            if tiled.focused == slotID {
                tiled.focused = tiled.columns.isEmpty ? nil : tiled.columns[min(i.column, tiled.columns.count - 1)].slots.first?.id
            }
            return true
        }
        guard let i = floating.firstIndex(where: { $0.slots[0].id == slotID }) else { return false }
        let column = floating.remove(at: i)
        let insertion = tiled.focused.flatMap { tiled.index(of: $0)?.column }.map { $0 + 1 } ?? tiled.columns.count
        tiled.columns.insert(column, at: insertion)
        tiled.focused = slotID
        return true
    }
}
