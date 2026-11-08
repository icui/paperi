import Testing
@testable import PaperiCore

struct CommandDispatchTests {
    let canvas = Rect(x: 0, y: 0, width: 1000, height: 600)
    let eligible = Classification(eligibility: .tiled, reason: "document")

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
