/// Events are scoped to one confirmed display/Space layout by the caller.
/// Missing AX enumeration entries are deliberately not removal events.
public enum LifecycleEvent: Sendable {
    case insert(Slot, width: Double, classification: Classification)
    case remove(slotID: String)
    /// Only affirmative platform evidence may replace native-tab membership.
    case confirmedTabs(Slot)
    case toggleFloating(slotID: String, classification: Classification)
    case focus(windowID: UInt32?, classification: Classification)
}

/// Pure lifecycle state. Intent is returned for a future scheduler; no OS effects run here.
public struct LifecycleState: Equatable, Sendable {
    public private(set) var layout: Layout
    public private(set) var floating: [Column]
    public private(set) var osFocusedWindow: UInt32?
    public private(set) var interactionSuppressed: Bool

    public init(layout: Layout = Layout(), floating: [Column] = []) {
        self.layout = layout
        self.floating = floating
        osFocusedWindow = nil
        interactionSuppressed = false
    }

    /// Suppressed lifecycle changes are retained without deferred centering/focus work.
    /// Invalid events are transactional: state remains unchanged if validation fails.
    @discardableResult
    public mutating func reduce(_ event: LifecycleEvent) throws -> Bool {
        try validate()
        var next = self
        var needsLayout = false
        switch event {
        case let .insert(slot, width, classification):
            guard classification.eligibility == .tiled || classification.eligibility == .floating else { return false }
            if let column = next.floating.first(where: { $0.slots.first?.id == slot.id }) {
                guard column.slots[0] == slot else { throw LayoutError.invalidMembership }
                return false
            }
            if let i = next.layout.index(of: slot.id) {
                // Repeated discovery is idempotent, but cannot silently change tabs.
                guard next.layout.columns[i.column].slots[i.row] == slot else {
                    throw LayoutError.invalidMembership
                }
                return false
            }
            if classification.eligibility == .floating {
                next.floating.append(Column(slots: [slot], width: width))
                break
            }
            let insertion = next.layout.focused.flatMap { next.layout.index(of: $0)?.column }
                .map { $0 + 1 } ?? next.layout.columns.count
            next.layout.columns.insert(Column(slots: [slot], width: width), at: insertion)
            if next.layout.focused == nil { next.layout.focused = slot.id }
            needsLayout = true
        case let .remove(slotID):
            if let i = next.floating.firstIndex(where: { $0.slots.first?.id == slotID }) {
                next.floating.remove(at: i)
                break
            }
            guard let i = next.layout.index(of: slotID) else { return false }
            next.layout.columns[i.column].slots.remove(at: i.row)
            next.layout.columns[i.column].weights.remove(at: i.row)
            if next.layout.columns[i.column].slots.isEmpty {
                next.layout.columns.remove(at: i.column)
            }
            if next.layout.focused == slotID {
                if next.layout.columns.isEmpty { next.layout.focused = nil }
                else {
                    let column = next.layout.columns[min(i.column, next.layout.columns.count - 1)]
                    next.layout.focused = column.slots[min(i.row, column.slots.count - 1)].id
                }
            }
            needsLayout = true
        case let .confirmedTabs(slot):
            if let i = next.floating.firstIndex(where: { $0.slots.first?.id == slot.id }) {
                next.floating[i].slots[0] = slot
                break
            }
            guard let i = next.layout.index(of: slot.id) else { throw LayoutError.invalidMembership }
            let previous = next.layout.columns[i.column].slots[i.row]
            next.layout.columns[i.column].slots[i.row] = slot
            needsLayout = previous.activeMember != slot.activeMember
        case let .toggleFloating(slotID, classification):
            // Commands during transient interactions are discarded, never replayed.
            guard !next.interactionSuppressed else { return false }
            var managed = LayoutState(tiled: next.layout, floating: next.floating)
            needsLayout = try managed.toggleFloating(slotID: slotID, classification: classification)
            next.layout = managed.tiled
            next.floating = managed.floating
        case let .focus(windowID, classification):
            next.osFocusedWindow = windowID
            next.interactionSuppressed = true
            if classification.eligibility == .tiled, let windowID {
                for column in next.layout.columns {
                    if let slot = column.slots.first(where: { $0.activeMember == windowID }) {
                        next.layout.focused = slot.id
                        next.interactionSuppressed = false
                    }
                }
            } else if classification.eligibility == .floating, let windowID {
                next.interactionSuppressed = !next.floating.contains { $0.slots[0].activeMember == windowID }
            }
        }
        try next.validate()
        self = next
        return needsLayout && !interactionSuppressed
    }

    public func validate() throws {
        try LayoutState(tiled: layout, floating: floating).validate()
    }
}
