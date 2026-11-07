/// Events are scoped to one confirmed display/Space layout by the caller.
/// Missing AX enumeration entries are deliberately not removal events.
public enum LifecycleEvent: Sendable {
    case insert(Slot, width: Double, classification: Classification)
    case remove(slotID: String)
    /// Only affirmative platform evidence may replace native-tab membership.
    case confirmedTabs(Slot)
    case focus(windowID: UInt32?, classification: Classification)
}

/// Pure lifecycle state. Intent is returned for a future scheduler; no OS effects run here.
public struct LifecycleState: Equatable, Sendable {
    public private(set) var layout: Layout
    public private(set) var osFocusedWindow: UInt32?
    public private(set) var interactionSuppressed: Bool

    public init(layout: Layout = Layout()) {
        self.layout = layout
        osFocusedWindow = nil
        interactionSuppressed = false
    }

    /// Suppressed lifecycle changes are retained without deferred centering/focus work.
    /// Invalid events are transactional: state remains unchanged if validation fails.
    @discardableResult
    public mutating func reduce(_ event: LifecycleEvent) throws -> Bool {
        try layout.validate()
        var next = self
        var needsLayout = false
        switch event {
        case let .insert(slot, width, classification):
            guard classification.eligibility == .tiled else { return false }
            if let i = next.layout.index(of: slot.id) {
                // Repeated discovery is idempotent, but cannot silently change tabs.
                guard next.layout.columns[i.column].slots[i.row] == slot else {
                    throw LayoutError.invalidMembership
                }
                return false
            }
            let insertion = next.layout.focused.flatMap { next.layout.index(of: $0)?.column }
                .map { $0 + 1 } ?? next.layout.columns.count
            next.layout.columns.insert(Column(slots: [slot], width: width), at: insertion)
            if next.layout.focused == nil { next.layout.focused = slot.id }
            needsLayout = true
        case let .remove(slotID):
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
            guard let i = next.layout.index(of: slot.id) else { throw LayoutError.invalidMembership }
            let previous = next.layout.columns[i.column].slots[i.row]
            next.layout.columns[i.column].slots[i.row] = slot
            needsLayout = previous.activeMember != slot.activeMember
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
            } else if classification.eligibility == .floating {
                next.interactionSuppressed = false
            }
        }
        try next.layout.validate()
        self = next
        return needsLayout && !interactionSuppressed
    }
}
