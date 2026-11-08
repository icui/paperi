import Foundation
import PaperiCore

/// State/ownership boundary shared by adapters. Native references and geometry
/// restoration remain the adapter's responsibility. No OS effects run here.
@MainActor final class ScopedLayoutSession {
    enum CommandOwnership { case frontmostApplication, applicationLocalFixture }
    let ownerPID: pid_t
    let canvas: Rect
    let ownership: CommandOwnership
    private(set) var ticket = UUID()
    private(set) var running = true
    private(set) var state = LifecycleState()
    private(set) var slots: [UInt32: String] = [:]
    private(set) var spaceID: UInt64?
    private var echoes = FrameEchoes()

    init(ownerPID: pid_t, canvas: Rect, ownership: CommandOwnership = .frontmostApplication) {
        self.ownerPID = ownerPID; self.canvas = canvas; self.ownership = ownership
    }

    func accepts(_ ticket: UUID) -> Bool { running && self.ticket == ticket }

    @discardableResult func insert(windowID: UInt32, ownerPID: pid_t, spaceID: UInt64,
                                   classification: Classification, knownSingleton: Bool = false,
                                   ticket: UUID) throws -> Bool {
        guard accepts(ticket), ownerPID == self.ownerPID, windowID > 0, spaceID > 0,
              canvas.isValid, knownSingleton, classification.eligibility == .tiled,
              self.spaceID == nil || self.spaceID == spaceID else { return false }
        let slotID = slots[windowID] ?? "container-\(UUID())"
        let intent = try state.reduce(.insert(Slot(id: slotID, members: [windowID], activeMember: windowID),
                                               width: (canvas.width - 8) / 2, classification: classification))
        self.spaceID = spaceID; slots[windowID] = slotID
        return intent
    }

    @discardableResult func remove(windowID: UInt32, ticket: UUID) throws -> Bool {
        guard accepts(ticket), let slot = slots[windowID] else { return false }
        let intent = try state.reduce(.remove(slotID: slot))
        slots.removeValue(forKey: windowID); echoes.remove(windowID: windowID)
        return intent
    }

    func focus(windowID: UInt32?, ownerPID: pid_t?, classification: Classification, ticket: UUID) throws {
        guard accepts(ticket) else { return }
        // Foreign/unavailable focus withholds commands while retaining the anchor.
        let id = ownerPID == self.ownerPID ? windowID : nil
        try state.reduce(.focus(windowID: id, classification: classification))
    }

    @discardableResult func resize(windowID: UInt32, ownerPID: pid_t, spaceID: UInt64,
                                   width: Double, classification: Classification, ticket: UUID) throws -> Bool {
        guard accepts(ticket), ownerPID == self.ownerPID, self.spaceID == spaceID,
              slots[windowID] != nil, width.isFinite, width > 0 else { return false }
        return try state.reduce(.resizeColumn(windowID: windowID, width: min(canvas.width, width), classification: classification))
    }

    @discardableResult func resizeFocused(by fraction: Double, frontmostPID: pid_t?, ticket: UUID) throws -> Bool {
        guard accepts(ticket), ownership == .applicationLocalFixture || frontmostPID == ownerPID else { return false }
        return try state.reduce(.resizeFocusedWidth(by: fraction, canvas: canvas))
    }

    @discardableResult func expect(windowID: UInt32, frame: Rect, now: Double, ticket: UUID) -> UInt64? {
        guard accepts(ticket), slots[windowID] != nil else { return nil }
        return echoes.expect(windowID: windowID, frame: frame, now: now)
    }

    func observe(windowID: UInt32, frame: Rect, now: Double, ticket: UUID) -> FrameEchoes.Observation {
        guard accepts(ticket) else { return .external }
        return echoes.observe(windowID: windowID, frame: frame, now: now)
    }

    func stop() {
        running = false; ticket = UUID()
        state = LifecycleState(); slots.removeAll(); echoes = FrameEchoes(); spaceID = nil
    }
}
