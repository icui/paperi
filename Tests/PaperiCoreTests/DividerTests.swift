import Testing
@testable import PaperiCore

struct DividerTests {
    let canvas = Rect(x: 0, y: 0, width: 1000, height: 600)

    func slot(_ n: Int) -> Slot { Slot(id: "s\(n)", members: [UInt32(n)], activeMember: UInt32(n)) }

    /// Columns of 300, 400 (stacked s2/s3) and 400 at x 0, 308 and 716.
    /// The third column runs past the right edge and is parked.
    func layout() -> Layout {
        Layout(columns: [Column(slots: [slot(1)], width: 300),
                         Column(slots: [slot(2), slot(3)], width: 400),
                         Column(slots: [slot(4)], width: 400)], focused: "s1")
    }

    @Test func listsOnCanvasColumnAndRowGaps() throws {
        let regions = try layout().dividers(in: canvas)
        #expect(regions.map(\.divider) == [.columns(0), .columns(1), .rows(column: 1, row: 0)])
        #expect(regions[0].gap == Rect(x: 300, y: 0, width: 8, height: 600))
        #expect(regions[0].position == 304)
        // Two rows of (600 - 8) / 2 = 296.
        #expect(regions[2].gap == Rect(x: 308, y: 296, width: 400, height: 8))
        #expect(regions[2].position == 300)
    }

    @Test func skipsGapsBesideParkedColumns() throws {
        var l = layout()
        l.offset = -600 // column 1 is parked off the left edge
        #expect(try !l.dividers(in: canvas).map(\.divider).contains(.columns(0)))
    }

    @Test func columnDividerKeepsOuterEdges() throws {
        var l = layout()
        #expect(try l.moveDivider(.columns(0), to: 404, in: canvas))
        #expect(l.columns[0].width == 400)
        #expect(l.columns[1].width == 300)
        let frames = try l.placements(in: canvas)
        #expect(frames[1].frame.x == 408)
        #expect(frames[1].frame.x + frames[1].frame.width == 708)
        #expect(frames[3].frame.x == 716) // later columns do not move
    }

    @Test func shrinkingSideStopsTheGap() throws {
        var l = layout()
        try l.moveDivider(.columns(0), to: 5000, in: canvas, minimum: 120)
        #expect(l.columns[1].width == 120)
        #expect(l.columns[0].width == 580)
        try l.moveDivider(.columns(0), to: -5000, in: canvas, minimum: 120)
        #expect(l.columns[0].width == 120)
        #expect(l.columns[1].width == 580)
        #expect(l.offset == 0)
    }

    @Test func learnedMinimumStopsTheGap() throws {
        var l = layout()
        try l.moveDivider(.columns(0), to: 704, in: canvas, minimum: 120, minimums: ["s3": 250])
        #expect(l.columns[1].width == 250)
        #expect(l.columns[0].width == 450)
    }

    @Test func cappedLeftColumnTravelsWithTheGap() throws {
        var l = layout()
        // s1 cannot grow past 350: it moves right with the gap while column 1 shrinks.
        try l.moveDivider(.columns(0), to: 504, in: canvas, maximums: ["s1": 350])
        #expect(l.columns[0].width == 350)
        #expect(l.columns[1].width == 200)
        #expect(l.offset == 150)
        let frames = try l.placements(in: canvas)
        #expect(frames[0].virtualX + 350 == 500)
        #expect(frames[1].frame.x + frames[1].frame.width == 708) // right edge unchanged
    }

    @Test func cappedRightColumnTravelsWithTheGap() throws {
        var l = layout()
        // Column 1 cannot grow past 450: it moves left with the gap, pulling column 2.
        try l.moveDivider(.columns(0), to: 154, in: canvas, maximums: ["s2": 450])
        #expect(l.columns[0].width == 150)
        #expect(l.columns[1].width == 450)
        #expect(l.offset == 0)
        let frames = try l.placements(in: canvas)
        #expect(frames[1].frame.x == 158)
        #expect(frames[3].virtualX == 616)
    }

    @Test func columnAlreadyBelowItsFloorDoesNotGrow() throws {
        var l = Layout(columns: [Column(slots: [slot(1)], width: 300), Column(slots: [slot(2)], width: 80)], focused: "s1")
        #expect(try !l.moveDivider(.columns(0), to: 400, in: canvas, minimum: 120))
        #expect(l.columns[1].width == 80)
    }

    @Test func columnDividerRespectsMaximumWidth() throws {
        var l = Layout(columns: [Column(slots: [slot(1)], width: 900), Column(slots: [slot(2)], width: 900)], focused: "s1")
        try l.moveDivider(.columns(0), to: 5000, in: canvas)
        #expect(l.columns[0].width == Layout.maxColumnWidth(in: canvas, edgeMargin: 8))
    }

    @Test func rowDividerResizesOnlyItsPair() throws {
        var l = Layout(columns: [Column(slots: [slot(1), slot(2), slot(3)], width: 400)], focused: "s1")
        // Rows of (600 - 16) / 3 each; drag the first gap 50 down.
        let before = try l.placements(in: canvas)
        let gap = try l.dividers(in: canvas).first { $0.divider == .rows(column: 0, row: 0) }!
        #expect(try l.moveDivider(.rows(column: 0, row: 0), to: gap.position + 50, in: canvas))
        let after = try l.placements(in: canvas)
        #expect(abs(after[0].frame.height - (before[0].frame.height + 50)) < 1e-9)
        #expect(abs(after[1].frame.height - (before[1].frame.height - 50)) < 1e-9)
        #expect(abs(after[2].frame.y - before[2].frame.y) < 1e-9)
        #expect(abs(after[2].frame.height - before[2].frame.height) < 1e-9)
    }

    @Test func shrinkingRowStopsTheGap() throws {
        var l = Layout(columns: [Column(slots: [slot(1), slot(2), slot(3)], width: 400)], focused: "s1")
        let gap = try l.dividers(in: canvas).first { $0.divider == .rows(column: 0, row: 0) }!
        let before = try l.placements(in: canvas).map(\.frame.height)
        try l.moveDivider(.rows(column: 0, row: 0), to: gap.position + 500, in: canvas, minimum: 120)
        let after = try l.placements(in: canvas).map(\.frame.height)
        #expect(abs(after[1] - 120) < 1e-9)
        #expect(abs(after[2] - before[2]) < 1e-9)
        #expect(abs(after[0] - (before[0] + before[1] - 120)) < 1e-9)
    }

    @Test func cappedRowPassesGrowthOn() throws {
        var l = Layout(columns: [Column(slots: [slot(1), slot(2), slot(3)], width: 400)], focused: "s1")
        let before = try l.placements(in: canvas).map(\.frame)
        let gap = try l.dividers(in: canvas).first { $0.divider == .rows(column: 0, row: 1) }!
        // Row 2 is at its cap, so it moves down with the gap and row 1 grows.
        try l.moveDivider(.rows(column: 0, row: 1), to: gap.position + 50, in: canvas,
                          maximums: ["s2": before[1].height])
        let after = try l.placements(in: canvas).map(\.frame)
        #expect(abs(after[1].height - before[1].height) < 1e-9)
        #expect(abs(after[1].y - (before[1].y + 50)) < 1e-9)
        #expect(abs(after[0].height - (before[0].height + 50)) < 1e-9)
        #expect(abs(after[2].height - (before[2].height - 50)) < 1e-9)
    }

    @Test func rowBoundaryGrabsAcrossEntireStackWidth() {
        let region = DividerRegion(divider: .rows(column: 0, row: 0),
            gap: Rect(x: 100, y: 396, width: 600, height: 8), position: 400)
        #expect(region.hitRegion(hitWidth: 16, length: 120) ==
            Rect(x: 100, y: 392, width: 600, height: 16))
        for x in [100.0, 130, 400, 699] {
            #expect(region.contains(x: x, y: 393, hitWidth: 16, length: 120))
            #expect(region.contains(x: x, y: 407, hitWidth: 16, length: 120))
        }
        #expect(!region.contains(x: 99, y: 400, hitWidth: 16, length: 120))
        #expect(!region.contains(x: 700, y: 400, hitWidth: 16, length: 120))
    }

    @Test func hitRegionIsACentredSegment() {
        let region = DividerRegion(divider: .columns(0), gap: Rect(x: 300, y: 0, width: 2, height: 600), position: 301)
        #expect(region.hitRegion(hitWidth: 10, length: 64) == Rect(x: 296, y: 268, width: 10, height: 64))
        #expect(region.contains(x: 296.5, y: 300, hitWidth: 10, length: 64))
        #expect(!region.contains(x: 295, y: 300, hitWidth: 10, length: 64))
        // Away from the middle the gap is left to the windows' own resizing.
        #expect(!region.contains(x: 301, y: 100, hitWidth: 10, length: 64))
        #expect(!region.contains(x: 301, y: 340, hitWidth: 10, length: 64))
        let row = DividerRegion(divider: .rows(column: 0, row: 0), gap: Rect(x: 0, y: 296, width: 40, height: 8), position: 300)
        #expect(row.hitRegion(hitWidth: 10, length: 64) == Rect(x: 0, y: 295, width: 40, height: 10))
    }
}
