import Testing
@testable import PaperiCore

/// Shift + trackpad edge resize: which edge moves, and how a lone column edge moves.
struct EdgeResizeTests {
    let canvas = Rect(x: 0, y: 0, width: 1000, height: 600)

    func slot(_ n: Int) -> Slot { Slot(id: "s\(n)", members: [UInt32(n)], activeMember: UInt32(n)) }

    /// Columns of 300, 400 (stacked s2/s3) and 400 at x 0, 308 and 716.
    func layout() -> Layout {
        Layout(columns: [Column(slots: [slot(1)], width: 300),
                         Column(slots: [slot(2), slot(3)], width: 400),
                         Column(slots: [slot(4)], width: 400)], focused: "s1")
    }

    /// s1 at 292–592 and s2 flush with the right edge at 600–1000.
    func rightAligned() -> Layout {
        Layout(columns: [Column(slots: [slot(1)], width: 300), Column(slots: [slot(2)], width: 400)],
               focused: "s2", offset: 292)
    }

    @Test func horizontalAlwaysMovesTheRightEdge() {
        #expect(layout().resizeEdge(of: "s1", vertical: false) == .columnEdge(0))
        #expect(layout().resizeEdge(of: "s3", vertical: false) == .columnEdge(1))
        #expect(rightAligned().resizeEdge(of: "s2", vertical: false) == .columnEdge(1))
        #expect(layout().resizeEdge(of: "nope", vertical: false) == nil)
    }

    @Test func verticalMovesTheGapBelowOrAboveTheBottomWindow() {
        let l = layout()
        #expect(l.resizeEdge(of: "s1", vertical: true) == nil)
        #expect(l.resizeEdge(of: "s2", vertical: true) == .rows(column: 1, row: 0))
        #expect(l.resizeEdge(of: "s3", vertical: true) == .rows(column: 1, row: 0))
        let three = Layout(columns: [Column(slots: [slot(1), slot(2), slot(3)], width: 400, weights: [3, 1, 1])])
        #expect(three.resizeEdge(of: "s1", vertical: true) == .rows(column: 0, row: 0))
        #expect(three.resizeEdge(of: "s2", vertical: true) == .rows(column: 0, row: 1))
        #expect(three.resizeEdge(of: "s3", vertical: true) == .rows(column: 0, row: 1))
    }

    @Test func columnEdgeRegionIsTheBandRightOfTheEdge() throws {
        let region = try layout().region(of: .columnEdge(0), in: canvas)
        #expect(region?.gap == Rect(x: 300, y: 0, width: 8, height: 600))
        #expect(region?.position == 304)
        #expect(try rightAligned().region(of: .columnEdge(1), in: canvas)?.position == 1004)
        #expect(try layout().region(of: .rows(column: 1, row: 0), in: canvas)?.position == 300)
    }

    /// A strip revealed flush right from fractional widths can leave the
    /// last edge a rounding error past the canvas; it must still resize.
    @Test func lastEdgeFlushRightAfterRoundingStillHasARegion() throws {
        let display = Rect(x: 8, y: 38, width: 1424, height: 886)
        var l = Layout(columns: [1061.7, 1098, 624.1, 1083.1].enumerated().map {
            Column(slots: [slot($0.offset + 1)], width: $0.element)
        }, focused: "s4")
        try l.reveal(in: display)
        let last = try l.placements(in: display)[3]
        #expect(last.virtualX + last.frame.width > display.x + display.width) // the rounding error
        let region = try l.region(of: .columnEdge(3), in: display)
        #expect(region != nil)
        #expect(try l.moveDivider(.columnEdge(3), to: region!.position - 300, in: display))
        let shrunk = try l.placements(in: display)[3]
        #expect(abs(shrunk.virtualX + shrunk.frame.width - 1432) < 0.001)
        #expect(abs(shrunk.frame.width - 783.1) < 0.001)
    }

    @Test func rightEdgeMovesAndPushesLaterColumns() throws {
        var l = layout()
        #expect(try l.moveDivider(.columnEdge(0), to: 504, in: canvas))
        #expect(l.columns[0].width == 500)
        #expect(l.columns[1].width == 400)
        #expect(l.offset == 0)
        #expect(try l.placements(in: canvas)[1].frame.x == 508)
        #expect(try l.moveDivider(.columnEdge(0), to: 204, in: canvas))
        #expect(l.columns[0].width == 200)
        #expect(l.offset == 0)
    }

    @Test func growingPastTheDisplayEdgeGrowsLeftward() throws {
        var l = rightAligned()
        #expect(try l.moveDivider(.columnEdge(1), to: 1104, in: canvas))
        #expect(l.columns[1].width == 500)
        let frames = try l.placements(in: canvas)
        #expect(frames[1].frame.x == 500)
        #expect(frames[1].frame.x + frames[1].frame.width == 1000)
        #expect(frames[0].frame.x == 192) // earlier columns scroll with it
        // Shrinking pulls the right edge in; the left edge stays.
        #expect(try l.moveDivider(.columnEdge(1), to: 904, in: canvas))
        #expect(l.columns[1].width == 400)
        #expect(try l.placements(in: canvas)[1].frame.x == 500)
    }

    @Test func wallKeepsTheMarginWhileColumnsFollow() throws {
        // s1 at 100–400 has later columns, so its wall is 1000 - 8; it caps
        // at 984 wide, which reaches the wall and scrolls 92.
        var l = layout()
        l.offset = 100
        try l.moveDivider(.columnEdge(0), to: 1204, in: canvas)
        #expect(l.columns[0].width == 984)
        let first = try l.placements(in: canvas)[0].frame
        #expect(first.x == 8)
        #expect(first.x + first.width == 992)
    }

    /// The live drag re-targets the same finger position after each app
    /// write, shifting the target by the strip's scroll since; that must
    /// settle rather than grow the window on every pass.
    @Test func retargetingAgainstTheWallIsStable() throws {
        var l = rightAligned()
        var grab = 0.0
        for _ in 0 ..< 3 {
            let before = l.offset
            try l.moveDivider(.columnEdge(1), to: 1104 - grab, in: canvas)
            grab -= l.offset - before
        }
        #expect(l.columns[1].width == 500)
        let frame = try l.placements(in: canvas)[1].frame
        #expect(frame.x + frame.width == 1000)
        // Moving the fingers back by 50 shrinks by 50 from the wall.
        try l.moveDivider(.columnEdge(1), to: 1054 - grab, in: canvas)
        #expect(l.columns[1].width == 450)
    }

    /// s1 (500) and s2 (300) partly off the left, s3 (400) flush right at 600–1000.
    func scrolledToEnd() -> Layout {
        Layout(columns: [Column(slots: [slot(1)], width: 500), Column(slots: [slot(2)], width: 300),
                         Column(slots: [slot(3)], width: 400)], focused: "s3", offset: -216)
    }

    @Test func shrinkingTheLastColumnKeepsItAgainstTheRightEdge() throws {
        var l = scrolledToEnd()
        #expect(try l.moveDivider(.columnEdge(2), to: 904, in: canvas))
        #expect(l.columns[2].width == 300)
        #expect(l.offset == -116)
        let frames = try l.placements(in: canvas)
        #expect(frames[2].frame.x == 700)
        #expect(frames[2].frame.x + frames[2].frame.width == 1000)
        #expect(frames[1].frame.x == 392) // earlier columns come into view
        // The strip's start stops at the left edge; then the right edge moves.
        #expect(try l.moveDivider(.columnEdge(2), to: 854, in: canvas))
        #expect(l.columns[2].width == 150)
        #expect(l.offset == 0)
        let end = try l.placements(in: canvas)[2].frame
        #expect(end.x == 816)
        #expect(end.x + end.width == 966)
    }

    @Test func shrinkingStaysPutWhenTheStripAlreadyStartsOnCanvas() throws {
        // rightAligned starts 292 in: shrinking s2 must not scroll further right.
        var l = rightAligned()
        try l.moveDivider(.columnEdge(1), to: 904, in: canvas)
        #expect(l.columns[1].width == 300)
        #expect(l.offset == 292)
        // A column that is not last leaves the room to the columns after it:
        // s2 at 292–592 shrinks to 200 without scrolling, and s3 follows.
        var m = scrolledToEnd()
        try m.moveDivider(.columnEdge(1), to: 496, in: canvas)
        #expect(m.columns[1].width == 200)
        #expect(m.offset == -216)
        #expect(try m.placements(in: canvas)[2].frame.x == 500)
    }

    @Test func retargetingAPinnedShrinkIsStable() throws {
        var l = scrolledToEnd()
        var grab = 0.0
        for _ in 0 ..< 3 {
            let before = l.offset
            try l.moveDivider(.columnEdge(2), to: 904 - grab, in: canvas)
            grab -= l.offset - before
        }
        #expect(l.columns[2].width == 300)
        #expect(l.offset == -116)
        // Fingers back to the start: the window grows to 400 again, leftward.
        try l.moveDivider(.columnEdge(2), to: 1004 - grab, in: canvas)
        #expect(l.columns[2].width == 400)
        #expect(l.offset == -216)
    }

    @Test func columnEdgeStopsAtLimits() throws {
        var l = layout()
        try l.moveDivider(.columnEdge(0), to: -5000, in: canvas, minimum: 120)
        #expect(l.columns[0].width == 120)
        try l.moveDivider(.columnEdge(0), to: 5000, in: canvas, maximums: ["s1": 450])
        #expect(l.columns[0].width == 450)
        #expect(l.offset == 0)
        try l.moveDivider(.columnEdge(0), to: 5000, in: canvas)
        #expect(l.columns[0].width == Layout.maxColumnWidth(in: canvas, edgeMargin: 8))
    }
}
