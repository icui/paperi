import ApplicationServices
import Foundation

/// Diagnostic AX equality tokens, scoped to one observer lifetime. Retaining
/// references permits comparison across samples, without titles or AX writes.
///
/// Elements are never released within a scope, so an app that keeps creating
/// and closing windows (e.g. a print popup per print) fills the table. A full
/// table withholds every capture of the app (`identityTruncated`); `renew()`
/// starts a fresh scope, and trackers keyed by the scope reset with it.
final class EvidenceIdentities {
    private(set) var scope = UUID().uuidString
    private let capacity: Int
    private var elements: [AXUIElement] = []
    private(set) var exhausted = false

    init(capacity: Int = 512) { self.capacity = max(0, capacity) }

    func token(for element: AXUIElement) -> Int? {
        if let index = elements.firstIndex(where: { CFEqual($0, element) }) { return index + 1 }
        guard elements.count < capacity else { exhausted = true; return nil }
        elements.append(element)
        return elements.count
    }

    /// Releases every retained element and starts a new scope. Tokens from
    /// the old scope are never reissued under it.
    func renew() {
        scope = UUID().uuidString
        elements.removeAll()
        exhausted = false
    }
}
