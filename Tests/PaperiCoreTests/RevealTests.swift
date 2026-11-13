import Testing
@testable import PaperiCore

struct RevealTests {
    let canvas = Rect(x: 0, y: 0, width: 1000, height: 600)

    func layout(focusing index: Int, offset: Double = 0) -> Layout {
        let columns = (1...4).map { Column(slots: [Slot(id: "s\($0)", members: [UInt32($0)], activeMember: UInt32($0))], width: 400) }
        return Layout(columns: columns, focused: "s\(index)", offset: offset)
    }

    @Test func revealScrollsMinimallyToTheRight() throws {
        var l = layout(focusing: 3)
        // Column 3 spans 816–1216; column 4 follows, so keep an 8 pt right margin.
        #expect(try l.reveal(in: canvas))
        #expect(l.offset == -224)
        #expect(try !l.reveal(in: canvas))
    }

    @Test func revealScrollsMinimallyToTheLeft() throws {
        var l = layout(focusing: 1, offset: -500)
        #expect(try l.reveal(in: canvas))
        #expect(l.offset == 0)
    }

    @Test func visibleColumnKeepsOffset() throws {
        var l = layout(focusing: 2)
        #expect(try !l.reveal(in: canvas))
        #expect(l.offset == 0)
    }

    @Test func revealKeepsMarginOnlyWhereNeighboursRemain() throws {
        // Column 2 is off the left edge with column 1 before it: inset by the margin.
        var l = layout(focusing: 2, offset: -900)
        #expect(try l.reveal(in: canvas))
        #expect(l.offset == 8 - 408)
        // The last column may sit flush against the right edge.
        var last = layout(focusing: 4)
        #expect(try last.reveal(in: canvas))
        #expect(last.offset == 1000 - 400 - 1224)
        // Full-width columns are capped at canvas − 2 margins, so both margins hold.
        var wide = Layout(columns: (1...3).map { Column(slots: [Slot(id: "w\($0)", members: [UInt32($0)], activeMember: UInt32($0))], width: 1000) },
                          focused: "w2", offset: 0)
        #expect(try wide.reveal(in: canvas))
        #expect(wide.offset == 8 - 992)
        let frames = try wide.placements(in: canvas)
        #expect(frames[1].frame.x == 8 && frames[1].frame.width == 984)
        #expect(frames[0].frame.x + frames[0].frame.width == 1)
        #expect(frames[2].frame.x == 999)
    }

    @Test func widthGrowthStopsAtTheMarginCap() throws {
        #expect(Layout.maxColumnWidth(in: canvas, edgeMargin: 8) == 984)
        #expect(Layout.maxColumnWidth(in: canvas, edgeMargin: 400) == 1000)
        var l = layout(focusing: 2)
        try l.resizeWidth(by: 2, in: canvas)
        #expect(l.columns[1].width == 984)
    }
}

struct NeighbourTests {
    @Test func neighboursAreTheFocusedColumnAndTheColumnsBesideIt() {
        let single = { (n: UInt32) in Column(slots: [Slot(id: "s\(n)", members: [n], activeMember: n)], width: 400) }
        let stacked = Column(slots: [Slot(id: "s3", members: [3], activeMember: 3),
                                     Slot(id: "s4", members: [4, 40], activeMember: 40)], width: 400)
        let columns = [single(1), single(2), stacked, single(5)]
        #expect(Layout(columns: columns, focused: "s5").neighbours() == [3, 40])
        #expect(Layout(columns: columns, focused: "s1").neighbours() == [2])
        #expect(Layout(columns: columns, focused: "s4").neighbours() == [2, 3, 5])
        #expect(Layout(columns: columns).neighbours().isEmpty)
    }
}
