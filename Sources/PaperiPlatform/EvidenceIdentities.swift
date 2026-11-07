import ApplicationServices
import Foundation

/// Diagnostic AX equality tokens, scoped to one observer lifetime. Retaining
/// references permits comparison across samples, without titles or AX writes.
final class EvidenceIdentities {
    let scope = UUID().uuidString
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
}
