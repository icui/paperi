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
        // Column 3 starts at 816 and ends at 1216: shift left by 216.
        #expect(try l.reveal(in: canvas))
        #expect(l.offset == -216)
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
}
