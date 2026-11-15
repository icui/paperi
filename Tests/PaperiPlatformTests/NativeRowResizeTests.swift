import Testing
import PaperiCore
@testable import PaperiPlatform

struct NativeRowResizeTests {
    @Test func nativeEdgesResizeBothRows() throws {
        let canvas = Rect(x: 0, y: 0, width: 900, height: 800)
        let a = Slot(id: "a", members: [1], activeMember: 1)
        let b = Slot(id: "b", members: [2], activeMember: 2)
        for topEdge in [false, true] {
            var layout = Layout(columns: [Column(slots: [a, b], width: 400)], focused: a.id)
            let before = try layout.placements(in: canvas, gap: 8)
            let old = before[topEdge ? 1 : 0].frame
            var actual = old
            if topEdge { actual.y += 40; actual.height -= 40 }
            else { actual.height += 40 }
            let resize = try #require(LiveReconciliation.rowResize(layout: layout,
                slotID: topEdge ? b.id : a.id, expected: old, actual: actual, gap: 8))
            #expect(try layout.moveDivider(resize.divider, to: resize.position, in: canvas, gap: 8))
            let after = try layout.placements(in: canvas, gap: 8)
            #expect(abs(after[0].frame.height - before[0].frame.height - 40) < 0.01)
            #expect(abs(after[1].frame.height - before[1].frame.height + 40) < 0.01)
            #expect(LiveReconciliation.rowResize(layout: layout, slotID: a.id,
                expected: old, actual: old, gap: 8) == nil)
        }
    }
}
