import Testing
@testable import PaperiCore

struct CommandDispatchTests {
    let canvas = Rect(x: 0, y: 0, width: 1000, height: 600)
    let eligible = Classification(eligibility: .tiled, reason: "document")

    @Test func columnAlignmentPreservesStructureAndSurvivesReveal() throws {
        let slots = (1...3).map { Slot(id: String($0), members: [UInt32($0)], activeMember: UInt32($0)) }
        var layout = Layout(columns: slots.map { Column(slots: [$0], width: 300) }, focused: "2")
        let columns = layout.columns
        try layout.align(.left, in: canvas)
        #expect(layout.offset == -300)
        #expect(try !layout.reveal(in: canvas))
        try layout.align(.right, in: canvas)
        #expect(layout.offset == 384)
        #expect(try !layout.reveal(in: canvas))
        try layout.align(.center, in: canvas)
        var centered = layout
        try centered.center(in: canvas)
        #expect(layout.offset == centered.offset)
        #expect(layout.columns == columns)
        #expect(layout.focused == "2")
        let original = layout
        #expect(throws: LayoutError.self) { try layout.align(.left, in: canvas, gap: .nan) }
        #expect(layout == original)
    }

    @Test func transientCommandsAreDiscardedAndRecoveryDoesNotReplay() throws {
        let slot = Slot(id: "container", members: [1, 2], activeMember: 2)
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot], width: 400)], focused: slot.id))
        #expect(try !state.reduce(.resizeFocusedWidth(by: 0.1, canvas: canvas)))
        try state.reduce(.focus(windowID: 2, classification: eligible))
        #expect(try state.reduce(.resizeFocusedWidth(by: 0.1, canvas: canvas)))
        let resized = state.layout
        try state.reduce(.focus(windowID: 99, classification: .init(eligibility: .excluded, reason: "panel")))
        #expect(try !state.reduce(.resizeFocusedWidth(by: 0.1, canvas: canvas)))
        #expect(state.layout == resized)
        try state.reduce(.focus(windowID: 2, classification: eligible))
        #expect(state.layout == resized)
        #expect(try state.reduce(.resizeFocusedWidth(by: 0.1, canvas: canvas)))
        #expect(state.layout.columns[0].width == 600)
        #expect(state.layout.columns[0].slots == [slot])
    }

    @Test func invalidCommandsAreTransactionalAndFloatingFocusCannotResizeTiledAnchor() throws {
        let tile = Slot(id: "tile", members: [1], activeMember: 1)
        let floating = Slot(id: "float", members: [2], activeMember: 2)
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [tile], width: 400)], focused: tile.id),
                                   floating: [Column(slots: [floating], width: 300)])
        try state.reduce(.focus(windowID: 1, classification: eligible))
        let original = state
        #expect(throws: LayoutError.self) { try state.reduce(.resizeFocusedWidth(by: .nan, canvas: canvas)) }
        #expect(state == original)
        try state.reduce(.focus(windowID: 2, classification: .init(eligibility: .floating, reason: "user")))
        #expect(try !state.reduce(.resizeFocusedWidth(by: 0.1, canvas: canvas)))
        #expect(state.layout == original.layout)
    }
}
