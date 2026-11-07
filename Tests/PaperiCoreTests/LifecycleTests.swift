import Testing
@testable import PaperiCore

struct LifecycleTests {
    let document = Classification(eligibility: .tiled, reason: "document")
    let overlay = Classification(eligibility: .excluded, reason: "overlay")
    func slot(_ id: UInt32) -> Slot { Slot(id: "\(id)", members: [id], activeMember: id) }

    @Test func insertionIsIdempotentAndInvalidMembershipIsAtomic() throws {
        var state = LifecycleState()
        #expect(try state.reduce(.insert(slot(1), width: 400, classification: document)))
        #expect(try !state.reduce(.insert(slot(1), width: 400, classification: document)))
        let before = state
        #expect(throws: (any Error).self) {
            try state.reduce(.insert(Slot(id: "duplicate", members: [1], activeMember: 1),
                                     width: 400, classification: document))
        }
        #expect(state == before)
        #expect(throws: (any Error).self) {
            try state.reduce(.insert(slot(2), width: .nan, classification: document))
        }
        #expect(state == before)
    }

    @Test func overlayPreservesManagedFocusAndNeverReplaysWork() throws {
        var state = LifecycleState()
        try state.reduce(.insert(slot(1), width: 400, classification: document))
        let layout = state.layout
        #expect(try !state.reduce(.focus(windowID: 99, classification: overlay)))
        #expect(state.layout == layout)
        #expect(state.osFocusedWindow == 99)
        #expect(state.interactionSuppressed)
        #expect(try !state.reduce(.insert(slot(99), width: 400, classification: overlay)))
        #expect(try !state.reduce(.insert(slot(2), width: 400, classification: document)))
        #expect(state.layout.columns.count == 2)
        #expect(try !state.reduce(.focus(windowID: 1, classification: document)))
        #expect(!state.interactionSuppressed)
        #expect(state.layout.focused == "1")
    }

    @Test func confirmedTabsRetainGeometryAndRejectConflictingMembers() throws {
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot(1)], width: 450),
                                                            Column(slots: [slot(3)], width: 300)],
                                                 focused: "1", offset: -70))
        let canvas = Rect(x: -1000, y: 20, width: 1000, height: 800)
        let frame = try state.layout.placements(in: canvas)[0].frame
        #expect(try state.reduce(.confirmedTabs(Slot(id: "1", members: [1, 2], activeMember: 2))))
        #expect(try state.layout.placements(in: canvas)[0].frame == frame)
        let before = state
        #expect(throws: (any Error).self) {
            try state.reduce(.confirmedTabs(Slot(id: "1", members: [2, 3], activeMember: 2)))
        }
        #expect(state == before)
        try state.reduce(.focus(windowID: 2, classification: document))
        #expect(state.layout.focused == "1")
        #expect(!state.interactionSuppressed)
    }

    @Test func removalChoosesExistingRowAndCleansEmptyColumns() throws {
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot(1), slot(2)], width: 400),
                                                            Column(slots: [slot(3)], width: 400)], focused: "2"))
        #expect(try state.reduce(.remove(slotID: "2")))
        #expect(state.layout.focused == "1")
        try state.reduce(.remove(slotID: "1"))
        #expect(state.layout.focused == "3")
        try state.reduce(.remove(slotID: "3"))
        #expect(state.layout.focused == nil)
        #expect(state.layout.columns.isEmpty)
        #expect(try !state.reduce(.remove(slotID: "3")))
        try state.layout.validate()
    }
}
