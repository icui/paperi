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
}
