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
        // Destruction of one native member does not prove its container closed.
        // Require an affirmative membership update before singleton removal.
        guard slots.values.filter({ $0 == slot }).count == 1 else { return false }
        let intent = try state.reduce(.remove(slotID: slot))
        for member in slots.keys.filter({ slots[$0] == slot }) {
            slots.removeValue(forKey: member); echoes.remove(windowID: member)
        }
        return intent
    }

    /// The caller must affirm the complete native membership, owner and Space.
    /// Selection-association candidates alone are not native-tab confirmation.
    /// Anchor identifies an existing container; detached members are not admitted
    /// as singletons until the caller supplies separate affirmative evidence.
    @discardableResult func confirmTabs(anchor: UInt32, members: [UInt32], active: UInt32,
                                        ownerPID: pid_t, spaceID: UInt64,
                                        classification: Classification, ticket: UUID) throws -> Bool {
        guard accepts(ticket), ownerPID == self.ownerPID, self.spaceID == spaceID,
              classification.eligibility == .tiled, let slotID = slots[anchor],
              !members.isEmpty, members.allSatisfy({ $0 > 0 }),
              Set(members).count == members.count, members.contains(active),
              members.allSatisfy({ slots[$0] == nil || slots[$0] == slotID }) else { return false }
        let intent = try state.reduce(.confirmedTabs(Slot(id: slotID, members: members, activeMember: active)))
        let previous = slots.keys.filter { slots[$0] == slotID }
        // Expectations belong to physical representatives, not logical slots.
        // Revoke all old echoes on representative/membership confirmation.
        for member in previous { slots.removeValue(forKey: member); echoes.remove(windowID: member) }
        for member in members { slots[member] = slotID }
        return intent
    }

    @discardableResult func admitTabs(members: [UInt32], active: UInt32, ownerPID: pid_t, spaceID: UInt64,
                                     classification: Classification, ticket: UUID) throws -> Bool {
        guard accepts(ticket), ownerPID == self.ownerPID, spaceID > 0,
              self.spaceID == nil || self.spaceID == spaceID, canvas.isValid,
              classification.eligibility == .tiled, members.count > 1,
              members.allSatisfy({ $0 > 0 && slots[$0] == nil }), Set(members).count == members.count,
              members.contains(active) else { return false }
        let id = "container-\(UUID())"
        let intent = try state.reduce(.insert(Slot(id: id, members: members, activeMember: active),
            width: (canvas.width - 8) / 2, classification: classification))
        for member in members { slots[member] = id }
        self.spaceID = spaceID
        return intent
    }

    func focus(windowID: UInt32?, ownerPID: pid_t?, classification: Classification, ticket: UUID) throws {
        guard accepts(ticket) else { return }
        // Foreign/unavailable focus withholds commands while retaining the anchor.
        let id = ownerPID == self.ownerPID ? windowID : nil
        try state.reduce(.focus(windowID: id, classification: classification))
    }

    /// Atomic topology reconciliation for the current one-slot-per-column native
    /// session. Detach retains the old active member's slot; merge retains the
    /// selected member's slot. Additions require explicit caller validation;
    /// missing closure proof rejects removals.
    @discardableResult func reconcileTabs(_ partitions: [NativeTabPartition], destroyed: Set<UInt32>,
                                         ownerPID: pid_t, spaceID: UInt64,
                                         classification: Classification, ticket: UUID,
                                         admitted: Set<UInt32> = []) throws -> Bool {
        guard accepts(ticket), self.ownerPID == ownerPID, self.spaceID == spaceID,
              classification.eligibility == .tiled, state.floating.isEmpty, state.suspended.isEmpty,
              state.layout.columns.allSatisfy({ $0.slots.count == 1 }) else { return false }
        let all = partitions.flatMap(\.members)
        guard partitions.allSatisfy({ !$0.members.isEmpty && $0.members.contains($0.active) }),
              admitted.allSatisfy({ $0 > 0 && slots[$0] == nil && !destroyed.contains($0) }),
              Set(all).count == all.count, Set(all) == Set(slots.keys).subtracting(destroyed).union(admitted) else { return false }
        let old = state.layout.columns
        var retained: Set<String> = []
        var columns: [(index: Int, column: Column)] = []
        var nextSlots: [UInt32: String] = [:]
        for partition in partitions {
            let sources = old.indices.filter { !Set(old[$0].slots[0].members).isDisjoint(with: partition.members) }
            guard let first = sources.first else { return false }
            let anchor = sources.first { old[$0].slots[0].activeMember == partition.active } ?? sources.first {
                partition.members.contains(old[$0].slots[0].activeMember)
            } ?? sources.first { source in
                partitions.filter { !Set(old[source].slots[0].members).isDisjoint(with: $0.members) }.count == 1
            }
            let source = anchor ?? first
            let existing = anchor.map { old[$0].slots[0].id }
            let id = existing.flatMap { retained.contains($0) ? nil : $0 } ?? "container-\(UUID())"
            retained.insert(id)
            let slot = Slot(id: id, members: partition.members, activeMember: partition.active)
            columns.append((source, Column(slots: [slot], width: old[source].width)))
            for member in partition.members { nextSlots[member] = id }
        }
        columns.sort {
            if $0.index != $1.index { return $0.index < $1.index }
            let original = old[$0.index].slots[0].id
            if ($0.column.slots[0].id == original) != ($1.column.slots[0].id == original) {
                return $0.column.slots[0].id == original
            }
            return $0.column.slots[0].members.min()! < $1.column.slots[0].members.min()!
        }
        let focused = state.layout.focused.flatMap { prior -> String? in
            if retained.contains(prior) { return prior }
            return old.first { $0.slots[0].id == prior }.flatMap { nextSlots[$0.slots[0].activeMember] }
        } ?? columns.first?.column.slots[0].id
        let layout = Layout(columns: columns.map(\.column), focused: focused, offset: state.layout.offset)
        var next = LifecycleState(layout: layout)
        if state.osFocusedWindow != nil || state.interactionSuppressed {
            let focusPolicy = state.interactionSuppressed ? WindowPolicy.classify(WindowFacts(bundleID: "unknown")) : classification
            try next.reduce(.focus(windowID: state.osFocusedWindow, classification: focusPolicy))
        }
        try next.validate()
        let changed = next.layout != state.layout
        state = next; slots = nextSlots
        if changed { echoes = FrameEchoes() }
        return changed
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
