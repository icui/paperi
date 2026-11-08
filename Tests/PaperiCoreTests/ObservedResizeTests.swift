import Testing
@testable import PaperiCore

struct ObservedResizeTests {
    let eligible = Classification(eligibility: .tiled, reason: "document")
    @Test func activeTabResizePreservesLogicalIdentityAndFocus() throws {
        let slot = Slot(id: "container", members: [1, 2], activeMember: 2)
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot], width: 400)], focused: slot.id))
        #expect(try state.reduce(.resizeColumn(windowID: 2, width: 480, classification: eligible)))
        #expect(state.layout.columns[0].width == 480)
        #expect(state.layout.columns[0].slots == [slot])
        #expect(state.layout.focused == slot.id)
        #expect(try !state.reduce(.resizeColumn(windowID: 1, width: 300, classification: eligible)))
        #expect(try !state.reduce(.resizeColumn(windowID: 2, width: 480, classification: eligible)))
        #expect(state.layout.columns[0].width == 480)
    }
    @Test func invalidExcludedAndSuppressedResizesCannotMutateLayout() throws {
        let slot = Slot(id: "ordinary", members: [1], activeMember: 1)
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot], width: 400)], focused: slot.id))
        let original = state
        #expect(throws: LayoutError.self) { try state.reduce(.resizeColumn(windowID: 1, width: .nan, classification: eligible)) }
        #expect(state == original)
        let excluded = Classification(eligibility: .excluded, reason: "popup")
        #expect(try !state.reduce(.resizeColumn(windowID: 1, width: 480, classification: excluded)))
        try state.reduce(.focus(windowID: nil, classification: excluded))
        #expect(try !state.reduce(.resizeColumn(windowID: 1, width: 480, classification: eligible)))
        #expect(state.layout == original.layout)
    }
}
