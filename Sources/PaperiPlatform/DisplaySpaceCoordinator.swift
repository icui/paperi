import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

/// One display's Space inventory and usable AX-coordinate canvas.
public struct DisplaySpaceTopology: Equatable, Sendable {
    public struct SpaceEntry: Equatable, Sendable {
        public let id: UInt64
        public let isUserSpace: Bool
        public init(id: UInt64, isUserSpace: Bool) { self.id = id; self.isUserSpace = isUserSpace }
    }
    public let displayUUID: String
    public let canvas: Rect
    public let spaces: [SpaceEntry]
    public let activeSpaceID: UInt64?

    public init(displayUUID: String, canvas: Rect, spaces: [SpaceEntry], activeSpaceID: UInt64?) {
        self.displayUUID = displayUUID; self.canvas = canvas; self.spaces = spaces; self.activeSpaceID = activeSpaceID
    }

    public var userSpaces: [UInt64] { spaces.filter(\.isUserSpace).map(\.id) }
}

/// Multi-display / multi-Space coordinator. Each user Space on each display owns
/// an independent `ScopedLayoutSession` so logical tab containers can move
/// between Spaces and displays without losing their slot ID, preferred width or
/// native-tab membership.
@MainActor final class DisplaySpaceCoordinator {
    private(set) var ownerPIDs: Set<pid_t>
    let ownership: ScopedLayoutSession.CommandOwnership
    private(set) var displays: [DisplaySpaceTopology]
    private(set) var sessions: [UInt64: ScopedLayoutSession] = [:]
    private(set) var spaceForWindow: [UInt32: UInt64] = [:]
    private(set) var running = true
    private(set) var ticket = UUID()

    convenience init(ownerPID: pid_t, displays: [DisplaySpaceTopology],
                     ownership: ScopedLayoutSession.CommandOwnership = .frontmostApplication) {
        self.init(ownerPIDs: [ownerPID], displays: displays, ownership: ownership)
    }

    init(ownerPIDs: Set<pid_t>, displays: [DisplaySpaceTopology],
         ownership: ScopedLayoutSession.CommandOwnership = .frontmostApplication) {
        self.ownerPIDs = ownerPIDs; self.displays = displays; self.ownership = ownership
        rebuildSessions()
    }

    func addOwner(_ pid: pid_t) {
        guard running, pid > 0 else { return }
        ownerPIDs.insert(pid)
        for session in sessions.values { session.addOwner(pid) }
    }

    /// Adopts fresh display/Space inventory. Existing sessions keep their logical
    /// state and adopt the (possibly changed) canvas of the display now hosting
    /// their Space; Spaces that vanished keep their session until it is empty so
    /// a transient enumeration gap never discards layout.
    func updateDisplays(_ next: [DisplaySpaceTopology]) {
        guard running, !next.isEmpty else { return }
        displays = next
        rebuildSessions()
        for display in next where display.canvas.isValid {
            for space in display.spaces where space.isUserSpace { sessions[space.id]?.setCanvas(display.canvas) }
        }
        let live = Set(next.flatMap(\.userSpaces))
        for (id, session) in sessions where !live.contains(id) && session.slots.isEmpty {
            session.stop(); sessions.removeValue(forKey: id)
        }
    }

    func session(containing windowID: UInt32) -> ScopedLayoutSession? {
        spaceForWindow[windowID].flatMap { sessions[$0] }
    }

    /// Removes the whole logical container holding `windowID` (closure of its
    /// last member, minimize, user float). Other containers keep their position.
    @discardableResult func removeContainer(containing windowID: UInt32,
                                            classification: Classification) throws -> [UInt32] {
        guard running, let spaceID = spaceForWindow[windowID], let session = sessions[spaceID],
              let slotID = session.slots[windowID], let loc = session.state.layout.index(of: slotID) else { return [] }
        let slot = session.state.layout.columns[loc.column].slots[loc.row]
        let others = session.state.layout.columns.flatMap(\.slots).filter { $0.id != slotID }
            .map { NativeTabPartition(members: $0.members, active: $0.activeMember) }
        guard let pid = session.ownerPIDs.first,
              try session.reconcileTabs(others, destroyed: Set(slot.members), ownerPID: pid, spaceID: spaceID,
                                        classification: classification, ticket: session.ticket) ||
                session.slots[windowID] == nil else { return [] }
        for member in slot.members { spaceForWindow.removeValue(forKey: member) }
        return slot.members
    }

    static func liveTopologies() -> [DisplaySpaceTopology] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var canvasByUUID: [String: Rect] = [:]
        var fallbackCanvas: Rect?
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "Main"
            let v = screen.visibleFrame
            let rect = Rect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height)
            if rect.isValid {
                canvasByUUID[uuid] = rect
                if fallbackCanvas == nil { fallbackCanvas = rect }
            }
        }
        guard let raw = paperi_copy_display_spaces() as? [[String: Any]], let fallback = fallbackCanvas else { return [] }
        let globalActive = paperi_active_space()
        return raw.compactMap { entry in
            let id = entry["Display Identifier"] as? String ?? "Main"
            let canvas = canvasByUUID[id] ?? fallback
            let list = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { row -> DisplaySpaceTopology.SpaceEntry? in
                guard let sid = (row["ManagedSpaceID"] as? NSNumber)?.uint64Value, sid > 0 else { return nil }
                return .init(id: sid, isUserSpace: paperi_space_type(sid) == 0)
            }
            let current = (entry["Current Space"] as? [String: Any]).flatMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
                ?? (list.contains { $0.id == globalActive } ? globalActive : list.first?.id)
            return list.isEmpty ? nil : DisplaySpaceTopology(displayUUID: id, canvas: canvas, spaces: list, activeSpaceID: current)
        }
    }

    private func rebuildSessions() {
        for display in displays where display.canvas.isValid {
            for space in display.spaces where space.isUserSpace && sessions[space.id] == nil {
                sessions[space.id] = ScopedLayoutSession(ownerPIDs: ownerPIDs, canvas: display.canvas, ownership: ownership)
            }
        }
    }

    func display(forSpace spaceID: UInt64) -> DisplaySpaceTopology? {
        displays.first { $0.spaces.contains { $0.id == spaceID } }
    }

    func numberedUserSpace(_ number: Int) -> UInt64? {
        guard number >= 1 else { return nil }
        let ordered = displays.flatMap(\.userSpaces)
        return ordered.indices.contains(number - 1) ? ordered[number - 1] : nil
    }

    @discardableResult func insertSingleton(windowID: UInt32, ownerPID: pid_t, spaceID: UInt64,
                                            classification: Classification, width: Double? = nil) throws -> Bool {
        guard running, spaceForWindow[windowID] == nil, let session = sessions[spaceID] else { return false }
        let inserted = try session.insert(windowID: windowID, ownerPID: ownerPID, spaceID: spaceID,
                                          classification: classification, knownSingleton: true,
                                          width: width, ticket: session.ticket)
        if session.slots[windowID] != nil { spaceForWindow[windowID] = spaceID }
        return inserted
    }

    @discardableResult func admitTabs(members: [UInt32], active: UInt32, ownerPID: pid_t, spaceID: UInt64,
                                      classification: Classification,
                                      allowActiveOnly: Bool = false, width: Double? = nil) throws -> Bool {
        guard running, members.allSatisfy({ spaceForWindow[$0] == nil }), let session = sessions[spaceID] else { return false }
        let admitted = try session.admitTabs(members: members, active: active, ownerPID: ownerPID,
                                             spaceID: spaceID, classification: classification,
                                             ticket: session.ticket, allowActiveOnly: allowActiveOnly, width: width)
        if admitted { for member in members { spaceForWindow[member] = spaceID } }
        return admitted
    }

    @discardableResult func reconcileTabs(in spaceID: UInt64, partitions: [NativeTabPartition],
                                          destroyed: Set<UInt32>, classification: Classification,
                                          admitted: Set<UInt32> = []) throws -> Bool {
        guard running, let session = sessions[spaceID],
              admitted.allSatisfy({ spaceForWindow[$0] == nil }) else { return false }
        guard let ownerPID = session.ownerPIDs.first else { return false }
        let changed = try session.reconcileTabs(partitions, destroyed: destroyed, ownerPID: ownerPID,
                                                spaceID: spaceID, classification: classification,
                                                ticket: session.ticket, admitted: admitted)
        let activeMembers = Set(session.slots.keys)
        for wid in destroyed { spaceForWindow.removeValue(forKey: wid) }
        for wid in activeMembers { spaceForWindow[wid] = spaceID }
        return changed
    }

    /// Moves a whole logical container (including all confirmed native-tab
    /// members) from its source Space session into `destinationSpace`, preserving
    /// its logical slot ID, preferred width and membership.
    @discardableResult func transferContainer(containing windowID: UInt32, to destinationSpace: UInt64,
                                              classification: Classification) throws -> (source: UInt64, destination: UInt64)? {
        guard running, classification.eligibility == .tiled,
              let sourceSpace = spaceForWindow[windowID], sourceSpace != destinationSpace,
              let source = sessions[sourceSpace], let destination = sessions[destinationSpace],
              let slotID = source.slots[windowID], let loc = source.state.layout.index(of: slotID) else { return nil }
        let slot = source.state.layout.columns[loc.column].slots[loc.row]
        let width = min(destination.canvas.width, source.state.layout.columns[loc.column].width)
        guard destination.spaceID == nil || destination.spaceID == destinationSpace,
              slot.members.allSatisfy({ destination.slots[$0] == nil }) else { return nil }
        let remaining = Set(source.slots.keys).subtracting(slot.members)
        var sourcePartitions: [NativeTabPartition] = []
        for col in source.state.layout.columns {
            for existing in col.slots where existing.id != slotID {
                sourcePartitions.append(.init(members: existing.members, active: existing.activeMember))
            }
        }
        guard remaining == Set(sourcePartitions.flatMap(\.members)) else { return nil }
        guard let ownerPID = source.ownerPIDs.first else { return nil }
        try source.reconcileTabs(sourcePartitions, destroyed: Set(slot.members), ownerPID: ownerPID,
                                 spaceID: sourceSpace, classification: classification, ticket: source.ticket)
        _ = try destination.insertSlot(slot, width: width, spaceID: destinationSpace,
                                       classification: classification, ticket: destination.ticket)
        for member in slot.members { spaceForWindow[member] = destinationSpace }
        return (sourceSpace, destinationSpace)
    }

    func stop() {
        running = false; ticket = UUID()
        for session in sessions.values { session.stop() }
        sessions.removeAll(); spaceForWindow.removeAll()
    }
}
