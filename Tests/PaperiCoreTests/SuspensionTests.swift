import Testing
@testable import PaperiCore

struct SuspensionTests {
    let document = Classification(eligibility: .tiled, reason: "document")
    let pending = Classification(eligibility: .pending, reason: "metadata unavailable")
    func slot(_ id: UInt32) -> Slot { Slot(id: "\(id)", members: [id], activeMember: id) }

    @Test func overlappingReasonsRequireEligibilityAndPreserveStack() throws {
        let original = Layout(columns: [Column(slots: [slot(1), slot(2)], width: 450, weights: [2, 3])], focused: "2")
        var state = LifecycleState(layout: original)
        #expect(try state.reduce(.suspend(slotID: "2", reason: .minimized)))
        #expect(try !state.reduce(.suspend(slotID: "2", reason: .hidden)))
        #expect(try !state.reduce(.suspend(slotID: "2", reason: .hidden)))
        #expect(state.suspended.count == 1)
        #expect(state.layout.focused == "1")
        #expect(try !state.reduce(.resume(slotID: "2", reason: .minimized, classification: document)))
        #expect(try !state.reduce(.resume(slotID: "2", reason: .hidden, classification: pending)))
        #expect(state.suspended.count == 1)
        #expect(try state.reduce(.resume(slotID: "2", reason: .hidden, classification: document)))
        #expect(state.layout.columns == original.columns)
        #expect(state.layout.focused == "1")
        #expect(state.suspended.isEmpty)
    }

    @Test func suspendedTabsReserveMembershipAndCloseDoesNotResurrect() throws {
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot(1)], width: 450)]))
        try state.reduce(.suspend(slotID: "1", reason: .fullscreen))
        #expect(try !state.reduce(.confirmedTabs(Slot(id: "1", members: [1, 2], activeMember: 2))))
        let before = state
        #expect(throws: (any Error).self) {
            try state.reduce(.insert(slot(2), width: 400, classification: document))
        }
        #expect(state == before)
        #expect(try !state.reduce(.insert(Slot(id: "1", members: [1, 2], activeMember: 2),
                                        width: 450, classification: document)))
        #expect(try !state.reduce(.remove(slotID: "1")))
        #expect(try !state.reduce(.resume(slotID: "1", reason: .fullscreen, classification: document)))
        #expect(state.suspended.isEmpty)
        #expect(state.layout.columns.isEmpty)
    }

    @Test func floatingRestoresWithoutTilingOrStealingFocus() throws {
        let floating = Classification(eligibility: .floating, reason: "user floating")
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot(1)], width: 400)], focused: "1"),
                                   floating: [Column(slots: [slot(2)], width: 550)])
        #expect(try !state.reduce(.suspend(slotID: "2", reason: .hidden)))
        #expect(state.floating.isEmpty)
        try state.reduce(.focus(windowID: 99, classification: pending))
        #expect(try !state.reduce(.resume(slotID: "2", reason: .hidden, classification: floating)))
        #expect(state.floating[0].width == 550)
        #expect(state.layout.focused == "1")
        #expect(state.interactionSuppressed)
        try state.validate()
    }

    @Test func restoreAfterSiblingClosesCreatesOneValidColumn() throws {
        var state = LifecycleState(layout: Layout(columns: [Column(slots: [slot(1), slot(2)], width: 450)]))
        try state.reduce(.suspend(slotID: "2", reason: .fullscreen))
        try state.reduce(.remove(slotID: "1"))
        #expect(try state.reduce(.resume(slotID: "2", reason: .fullscreen, classification: document)))
        #expect(state.layout.columns.count == 1)
        #expect(state.layout.focused == "2")
        #expect(state.layout.columns[0].width == 450)
        try state.validate()
    }
}
