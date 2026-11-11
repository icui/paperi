import Foundation
import PaperiCore

/// State/ownership boundary shared by adapters. Native references and geometry
/// restoration remain the adapter's responsibility. No OS effects run here.
@MainActor final class ScopedLayoutSession {
    enum CommandOwnership { case frontmostApplication, applicationLocalFixture }
    private(set) var ownerPIDs: Set<pid_t>
    private(set) var canvas: Rect
    let ownership: CommandOwnership
    private(set) var ticket = UUID()
    private(set) var running = true
    private(set) var state = LifecycleState()
    private(set) var slots: [UInt32: String] = [:]
    private(set) var spaceID: UInt64?
    private var echoes = FrameEchoes()

    convenience init(ownerPID: pid_t, canvas: Rect, ownership: CommandOwnership = .frontmostApplication) {
        self.init(ownerPIDs: [ownerPID], canvas: canvas, ownership: ownership)
    }

    init(ownerPIDs: Set<pid_t>, canvas: Rect, ownership: CommandOwnership = .frontmostApplication) {
        self.ownerPIDs = ownerPIDs; self.canvas = canvas; self.ownership = ownership
    }

    func owns(_ pid: pid_t?) -> Bool { pid.map(ownerPIDs.contains) ?? false }

    /// Allowlisted applications may launch after the session starts.
    func addOwner(_ pid: pid_t) { if running, pid > 0 { ownerPIDs.insert(pid) } }

    /// Display geometry changes (resolution, Dock, menu bar) keep logical state;
    /// column widths are clamped by placement to the new canvas width.
    @discardableResult func setCanvas(_ next: Rect) -> Bool {
        guard running, next.isValid, next != canvas else { return false }
        canvas = next; echoes = FrameEchoes()
        return true
    }

    func accepts(_ ticket: UUID) -> Bool { running && self.ticket == ticket }

    @discardableResult func insert(windowID: UInt32, ownerPID: pid_t, spaceID: UInt64,
                                   classification: Classification, knownSingleton: Bool = false,
                                   width: Double? = nil, ticket: UUID) throws -> Bool {
        guard accepts(ticket), owns(ownerPID), windowID > 0, spaceID > 0,
              canvas.isValid, knownSingleton, classification.eligibility == .tiled,
              self.spaceID == nil || self.spaceID == spaceID else { return false }
        let slotID = slots[windowID] ?? "container-\(UUID())"
        let intent = try state.reduce(.insert(Slot(id: slotID, members: [windowID], activeMember: windowID),
                                               width: admissionWidth(width), classification: classification))
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
        guard accepts(ticket), owns(ownerPID), self.spaceID == spaceID,
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
                                     classification: Classification, ticket: UUID,
                                     allowActiveOnly: Bool = false, width: Double? = nil) throws -> Bool {
        guard accepts(ticket), owns(ownerPID), spaceID > 0,
              self.spaceID == nil || self.spaceID == spaceID, canvas.isValid,
              classification.eligibility == .tiled,
              allowActiveOnly ? !members.isEmpty : members.count > 1,
              members.allSatisfy({ $0 > 0 && slots[$0] == nil }), Set(members).count == members.count,
              members.contains(active) else { return false }
        let id = "container-\(UUID())"
        let intent = try state.reduce(.insert(Slot(id: id, members: members, activeMember: active),
            width: admissionWidth(width), classification: classification))
        for member in members { slots[member] = id }
        self.spaceID = spaceID
        return intent
    }

    /// A caller-preferred width (the window's own or remembered width, as in
    /// PaperWM) clamped to the canvas; otherwise half the canvas.
    private func admissionWidth(_ preferred: Double?) -> Double {
        guard let preferred, preferred.isFinite, preferred > 0 else { return (canvas.width - 8) / 2 }
        return min(canvas.width, max(min(canvas.width, 100), preferred))
    }

    /// Every member of the container holding `windowID` (native tabs included).
    func members(of windowID: UInt32) -> [UInt32]? {
        guard let slotID = slots[windowID] else { return nil }
        return slots.filter { $0.value == slotID }.map(\.key).sorted()
    }

    @discardableResult func insertSlot(_ slot: Slot, width: Double, spaceID: UInt64,
                                       classification: Classification, ticket: UUID) throws -> Bool {
        guard accepts(ticket), spaceID > 0, self.spaceID == nil || self.spaceID == spaceID,
              canvas.isValid, width.isFinite, width > 0, classification.eligibility == .tiled,
              !slot.members.isEmpty, slot.members.contains(slot.activeMember),
              Set(slot.members).count == slot.members.count,
              slot.members.allSatisfy({ $0 > 0 && slots[$0] == nil }) else { return false }
        let intent = try state.reduce(.insert(slot, width: width, classification: classification))
        for member in slot.members { slots[member] = slot.id }
        self.spaceID = spaceID
        return intent
    }

    func focus(windowID: UInt32?, ownerPID: pid_t?, classification: Classification, ticket: UUID) throws {
        guard accepts(ticket) else { return }
        // Foreign/unavailable focus withholds commands while retaining the anchor.
        let id = owns(ownerPID) ? windowID : nil
        try state.reduce(.focus(windowID: id, classification: classification))
    }

    /// Atomic topology reconciliation across single-slot and stacked columns.
    /// Detach retains the old active member's slot at its original column/row and
    /// places the detached sibling in an adjacent column; merge retains the
    /// selected member's slot, column width and stack weight. Additions require
    /// explicit caller validation; missing closure proof rejects removals.
    @discardableResult func reconcileTabs(_ partitions: [NativeTabPartition], destroyed: Set<UInt32>,
                                         ownerPID: pid_t, spaceID: UInt64,
                                         classification: Classification, ticket: UUID,
                                         admitted: Set<UInt32> = []) throws -> Bool {
        guard accepts(ticket), owns(ownerPID), self.spaceID == spaceID,
              classification.eligibility == .tiled, state.floating.isEmpty, state.suspended.isEmpty else { return false }
        let all = partitions.flatMap(\.members)
        guard partitions.allSatisfy({ !$0.members.isEmpty && $0.members.contains($0.active) }),
              admitted.allSatisfy({ $0 > 0 && slots[$0] == nil && !destroyed.contains($0) }),
              Set(all).count == all.count, Set(all) == Set(slots.keys).subtracting(destroyed).union(admitted) else { return false }
        struct Entry { let column: Int; let row: Int; let slot: Slot; let width: Double; let weight: Double }
        let old = state.layout.columns.enumerated().flatMap { c, col in
            col.slots.enumerated().map { r, slot in Entry(column: c, row: r, slot: slot, width: col.width, weight: col.weights[r]) }
        }
        var retained: Set<String> = []
        var nextSlots: [UInt32: String] = [:]
        var inColumn: [Int: [(row: Int, slot: Slot, weight: Double)]] = [:]
        var detached: [Int: [(row: Int, slot: Slot, width: Double)]] = [:]
        for partition in partitions {
            let sources = old.indices.filter { !Set(old[$0].slot.members).isDisjoint(with: partition.members) }
            guard let first = sources.first else { return false }
            let anchor = sources.first { old[$0].slot.activeMember == partition.active } ?? sources.first {
                partition.members.contains(old[$0].slot.activeMember)
            } ?? sources.first { source in
                partitions.filter { !Set(old[source].slot.members).isDisjoint(with: $0.members) }.count == 1
            }
            let source = old[anchor ?? first]
            if let anchor, !retained.contains(old[anchor].slot.id) {
                let id = old[anchor].slot.id
                retained.insert(id)
                let slot = Slot(id: id, members: partition.members, activeMember: partition.active)
                inColumn[source.column, default: []].append((source.row, slot, source.weight))
                for member in partition.members { nextSlots[member] = id }
            } else {
                let id = "container-\(UUID())"
                retained.insert(id)
                let slot = Slot(id: id, members: partition.members, activeMember: partition.active)
                detached[source.column, default: []].append((source.row, slot, source.width))
                for member in partition.members { nextSlots[member] = id }
            }
        }
        var rebuilt: [Column] = []
        for c in state.layout.columns.indices {
            if let rows = inColumn[c]?.sorted(by: {
                $0.row != $1.row ? $0.row < $1.row : $0.slot.members.min()! < $1.slot.members.min()!
            }), !rows.isEmpty {
                rebuilt.append(Column(slots: rows.map(\.slot), width: state.layout.columns[c].width, weights: rows.map(\.weight)))
            }
            if let extra = detached[c]?.sorted(by: {
                $0.row != $1.row ? $0.row < $1.row : $0.slot.members.min()! < $1.slot.members.min()!
            }) {
                for item in extra { rebuilt.append(Column(slots: [item.slot], width: item.width)) }
            }
        }
        let focused = state.layout.focused.flatMap { prior -> String? in
            if retained.contains(prior) { return prior }
            return old.first { $0.slot.id == prior }.flatMap { nextSlots[$0.slot.activeMember] }
        } ?? rebuilt.first?.slots.first?.id
        let layout = Layout(columns: rebuilt, focused: focused, offset: state.layout.offset)
        var next = LifecycleState(layout: layout)
        if state.osFocusedWindow != nil || state.interactionSuppressed {
            let focusPolicy = state.interactionSuppressed ? WindowPolicy.classify(WindowFacts(bundleID: "unknown")) : classification
            let effectiveFocus = state.osFocusedWindow.flatMap { wid -> UInt32? in
                guard !state.interactionSuppressed, let slotID = nextSlots[wid],
                      let loc = next.layout.index(of: slotID) else { return wid }
                return next.layout.columns[loc.column].slots[loc.row].activeMember
            }
            try next.reduce(.focus(windowID: effectiveFocus, classification: focusPolicy))
        }
        try next.validate()
        let changed = next.layout != state.layout
        state = next; slots = nextSlots
        if changed { echoes = FrameEchoes() }
        return changed
    }

    private static let tiledClassification = WindowPolicy.classify(
        WindowFacts(bundleID: "session", role: "AXWindow", subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true, level: 0)
    )

    /// Applies a pure layout command to the focused tiled container. Commands
    /// are discarded (never replayed) while focus is foreign or transient.
    @discardableResult func command(frontmostPID: pid_t?, ticket: UUID,
                                    _ body: (inout Layout) throws -> Void) throws -> Bool {
        guard accepts(ticket), ownership == .applicationLocalFixture || owns(frontmostPID),
              !state.interactionSuppressed else { return false }
        var layout = state.layout
        try body(&layout)
        guard layout != state.layout else { return false }
        var next = LifecycleState(layout: layout, floating: state.floating)
        if let focused = state.osFocusedWindow {
            try next.reduce(.focus(windowID: focused, classification: Self.tiledClassification))
        }
        try next.validate(); state = next; echoes = FrameEchoes()
        return true
    }

    @discardableResult func slurpFocused(frontmostPID: pid_t?, ticket: UUID) throws -> Bool {
        try command(frontmostPID: frontmostPID, ticket: ticket) { $0.slurp() }
    }

    @discardableResult func barfFocused(frontmostPID: pid_t?, ticket: UUID) throws -> Bool {
        try command(frontmostPID: frontmostPID, ticket: ticket) { $0.barf() }
    }

    /// Scrolls the strip without changing focus (reveal/center after focus moves).
    @discardableResult func setOffset(_ offset: Double, ticket: UUID) -> Bool {
        guard accepts(ticket), offset.isFinite, offset != state.layout.offset else { return false }
        var layout = state.layout; layout.offset = offset
        var next = LifecycleState(layout: layout, floating: state.floating)
        if let focused = state.osFocusedWindow {
            _ = try? next.reduce(.focus(windowID: focused, classification: Self.tiledClassification))
        }
        guard (try? next.validate()) != nil else { return false }
        state = next
        return true
    }

    /// Drops the slot holding `windowID` on slot `target` after a user drag
    /// (swap, stack or new column); focus is unchanged.
    @discardableResult func drop(windowID: UInt32, on target: String, action: DropAction, ticket: UUID) -> Bool {
        guard accepts(ticket), let id = slots[windowID] else { return false }
        var layout = state.layout
        guard layout.drop(id, on: target, action: action) else { return false }
        var next = LifecycleState(layout: layout, floating: state.floating)
        if let focused = state.osFocusedWindow {
            _ = try? next.reduce(.focus(windowID: focused, classification: Self.tiledClassification))
        }
        guard (try? next.validate()) != nil else { return false }
        state = next; echoes = FrameEchoes()
        return true
    }

    @discardableResult func resize(windowID: UInt32, ownerPID: pid_t, spaceID: UInt64,
                                   width: Double, classification: Classification, ticket: UUID) throws -> Bool {
        guard accepts(ticket), owns(ownerPID), self.spaceID == spaceID,
              slots[windowID] != nil, width.isFinite, width > 0 else { return false }
        return try state.reduce(.resizeColumn(windowID: windowID, width: min(canvas.width, width), classification: classification))
    }

    @discardableResult func resizeFocused(by fraction: Double, frontmostPID: pid_t?, ticket: UUID) throws -> Bool {
        guard accepts(ticket), ownership == .applicationLocalFixture || owns(frontmostPID) else { return false }
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
