import Testing
import PaperiCore
@testable import PaperiPlatform

@MainActor struct ScopedLayoutSessionTests {
    let canvas = Rect(x: 0, y: 0, width: 1000, height: 600)
    var eligible: Classification { WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow",
        subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true, level: 0)) }

    @Test func admissionRequiresKnownMembershipOwnerAndOneSpace() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        let ticket = session.ticket
        #expect(try !session.insert(windowID: 1, ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket))
        #expect(try !session.insert(windowID: 1, ownerPID: 99, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket))
        #expect(session.slots.isEmpty)
        #expect(try session.insert(windowID: 1, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket))
        let slot = session.slots[1]
        #expect(try !session.insert(windowID: 1, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket))
        #expect(session.slots[1] == slot)
        #expect(try !session.insert(windowID: 2, ownerPID: 42, spaceID: 8, classification: eligible, knownSingleton: true, ticket: ticket))
        #expect(session.slots.count == 1)
    }

    @Test func commandsRequireActualOwnerEvenWithRetainedDocumentFocus() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        let ticket = session.ticket
        try session.insert(windowID: 1, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket)
        try session.focus(windowID: 1, ownerPID: 42, classification: eligible, ticket: ticket)
        let original = session.state
        #expect(try !session.resizeFocused(by: 0.1, frontmostPID: 99, ticket: ticket))
        #expect(try !session.resizeFocused(by: 0.1, frontmostPID: nil, ticket: ticket))
        #expect(session.state == original)
        #expect(try session.resizeFocused(by: 0.1, frontmostPID: 42, ticket: ticket))
        try session.focus(windowID: 1, ownerPID: 99, classification: eligible, ticket: ticket)
        #expect(session.state.interactionSuppressed)
        #expect(try !session.resizeFocused(by: 0.1, frontmostPID: 42, ticket: ticket))
    }

    @Test func stoppedSessionRejectsQueuedLifecycleCommandsAndEffects() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        let ticket = session.ticket
        try session.insert(windowID: 1, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket)
        session.expect(windowID: 1, frame: canvas, now: 10, ticket: ticket)
        session.stop()
        #expect(!session.accepts(ticket))
        #expect(!session.accepts(session.ticket))
        #expect(try !session.insert(windowID: 2, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket))
        #expect(try !session.remove(windowID: 1, ticket: ticket))
        #expect(try !session.resizeFocused(by: 0.1, frontmostPID: 42, ticket: ticket))
        #expect(session.expect(windowID: 1, frame: canvas, now: 11, ticket: ticket) == nil)
        #expect(session.observe(windowID: 1, frame: canvas, now: 11, ticket: ticket) == .external)
        #expect(session.state.layout.columns.isEmpty)
        let replacement = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        #expect(!replacement.accepts(ticket))
    }

    @Test func nativeRepresentativeSwitchPreservesSlotWidthAndRevokesPhysicalEchoes() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        let ticket = session.ticket
        try session.insert(windowID: 1, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket)
        let original = session.state.layout.columns[0]
        session.expect(windowID: 1, frame: canvas, now: 10, ticket: ticket)
        #expect(try session.confirmTabs(anchor: 1, members: [1, 2], active: 2, ownerPID: 42,
                                       spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.slots[1] == session.slots[2])
        #expect(try !session.remove(windowID: 2, ticket: ticket))
        #expect(session.state.layout.columns[0].width == original.width)
        #expect(session.state.layout.columns[0].slots[0].id == original.slots[0].id)
        #expect(session.observe(windowID: 1, frame: canvas, now: 10.1, ticket: ticket) == .external)
        #expect(try session.confirmTabs(anchor: 2, members: [1, 2], active: 1, ownerPID: 42,
                                       spaceID: 7, classification: eligible, ticket: ticket))
        // Closing the active member is a membership update, not container removal.
        try session.confirmTabs(anchor: 1, members: [2], active: 2, ownerPID: 42,
                                spaceID: 7, classification: eligible, ticket: ticket)
        #expect(session.slots[1] == nil)
        #expect(session.slots[2] == original.slots[0].id)
        #expect(try !session.remove(windowID: 1, ticket: ticket))
        #expect(try session.remove(windowID: 2, ticket: ticket))
        #expect(session.slots.isEmpty && session.state.layout.columns.isEmpty)
    }

    @Test func detachedMemberRequiresFreshAdmissionAndCannotKeepAnOldEcho() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        let ticket = session.ticket
        try session.insert(windowID: 1, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket)
        try session.confirmTabs(anchor: 1, members: [1, 2], active: 2, ownerPID: 42,
                                spaceID: 7, classification: eligible, ticket: ticket)
        session.expect(windowID: 2, frame: canvas, now: 10, ticket: ticket)
        try session.confirmTabs(anchor: 2, members: [1], active: 1, ownerPID: 42,
                                spaceID: 7, classification: eligible, ticket: ticket)
        #expect(session.slots[2] == nil && session.state.layout.columns.count == 1)
        #expect(session.observe(windowID: 2, frame: canvas, now: 10.1, ticket: ticket) == .external)
        #expect(try !session.insert(windowID: 2, ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket))
        #expect(try session.insert(windowID: 2, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket))
        #expect(session.slots[1] != session.slots[2])
    }

    @Test func completeGroupAdmissionDoesNotRequirePretendingMembersAreSingletons() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        let ticket = session.ticket
        #expect(try !session.admitTabs(members: [1, 2], active: 2, ownerPID: 99,
                                      spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.slots.isEmpty)
        #expect(try session.admitTabs(members: [1, 2], active: 2, ownerPID: 42,
                                     spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.slots.count == 2 && session.slots[1] == session.slots[2])
        #expect(session.state.layout.columns.count == 1)
        #expect(try !session.admitTabs(members: [2, 3], active: 3, ownerPID: 42,
                                      spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.slots[3] == nil)
    }

    @Test func nativeConfirmationRejectsConflictingOwnershipAndStaleEvidenceTransactionally() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: canvas)
        let ticket = session.ticket
        for id: UInt32 in [1, 3] {
            try session.insert(windowID: id, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket)
        }
        let before = session.state
        for members: [UInt32] in [[1, 3], [1, 1], [0, 1], []] {
            #expect(try !session.confirmTabs(anchor: 1, members: members, active: 1, ownerPID: 42,
                                            spaceID: 7, classification: eligible, ticket: ticket))
        }
        #expect(try !session.confirmTabs(anchor: 1, members: [1, 2], active: 2, ownerPID: 99,
                                        spaceID: 7, classification: eligible, ticket: ticket))
        #expect(try !session.confirmTabs(anchor: 1, members: [1, 2], active: 2, ownerPID: 42,
                                        spaceID: 8, classification: eligible, ticket: ticket))
        #expect(session.state == before && session.slots.count == 2)
        session.stop()
        #expect(try !session.confirmTabs(anchor: 1, members: [1, 2], active: 2, ownerPID: 42,
                                        spaceID: 7, classification: eligible, ticket: ticket))
    }
}
