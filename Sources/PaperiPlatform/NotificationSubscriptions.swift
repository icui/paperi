import ApplicationServices

/// Successful registrations belong to one AXObserver. Failed requests remain
/// eligible for a later bounded retry; equal AX references share coverage.
struct NotificationSubscriptions {
    private var entries: [(element: AXUIElement, names: Set<String>)] = []

    mutating func register(_ element: AXUIElement, name: String,
                           perform: () -> AXError) -> AXError? {
        let index = entries.firstIndex { CFEqual($0.element, element) }
        if let index, entries[index].names.contains(name) { return nil }
        let result = perform()
        if result == .success || result == .notificationAlreadyRegistered {
            if let index {
                entries[index].names.insert(name)
            } else {
                entries.append((element, [name]))
            }
        }
        return result
    }

    mutating func remove(_ element: AXUIElement) {
        entries.removeAll { CFEqual($0.element, element) }
    }
}
