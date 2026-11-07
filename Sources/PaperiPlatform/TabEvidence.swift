import AppKit
import ApplicationServices
import PaperiBridge

extension Diagnostics {
    /// Bounded structural evidence only: no labels, titles, descriptions or
    /// string values. Local node IDs are meaningful within this capture only.
    @MainActor public static func tabEvidence(bundleID: String) -> [String: Any] {
        tabEvidence(bundleID: bundleID, observedWindows: [:])
    }

    @MainActor static func tabEvidence(bundleID: String, observedWindows: [pid_t: [AXUIElement]],
                                      identities: [pid_t: EvidenceIdentities] = [:]) -> [String: Any] {
        var applications: [[String: Any]] = []
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
            let windows = value as? [AXUIElement] ?? []
            let observed = observedWindows[app.processIdentifier] ?? []
            let identity = identities[app.processIdentifier]
            let applicationRole = attribute(application, kAXRoleAttribute) as? String ?? "unknown"
            var nodes: [AXUIElement] = []
            var rows: [[String: Any]] = []
            var truncated = false
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            func withinBudget() -> Bool {
                guard ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return false }
                return true
            }
            func visit(_ element: AXUIElement, depth: Int) -> Int? {
                if let index = nodes.firstIndex(where: { CFEqual($0, element) }) { return index }
                guard depth <= 5, nodes.count < 128, withinBudget() else { truncated = true; return nil }
                let index = nodes.count
                nodes.append(element)
                rows.append([:])
                AXUIElementSetMessagingTimeout(element, 0.15)
                var row: [String: Any] = ["node": index]
                if let token = identity?.token(for: element) { row["axIdentity"] = token }
                if let root = windows.firstIndex(where: { CFEqual($0, element) }) { row["enumeratedWindowIndex"] = root }
                if let root = observed.firstIndex(where: { CFEqual($0, element) }) { row["observedWindowIndex"] = root }
                let id = paperi_window_id(element)
                if id != 0 { row["windowID"] = id }
                for name in [kAXRoleAttribute, kAXSubroleAttribute] {
                    guard withinBudget() else { break }
                    if let value = attribute(element, name) as? String { row[name] = value }
                }
                for name in ["AXSelected", "AXValue"] {
                    guard withinBudget() else { break }
                    if let value = attribute(element, name), CFGetTypeID(value) == CFBooleanGetTypeID() {
                        row[name] = value as! CFBoolean
                    }
                }
                var attributes: CFArray?
                if withinBudget() {
                    row["attributeNamesError"] = AXUIElementCopyAttributeNames(element, &attributes).rawValue
                }
                if let names = attributes as? [String] { row["attributeNames"] = names.sorted() }
                for name in ["AXTabs", "AXChildren", "AXSelectedChildren", "AXWindow", "AXTopLevelUIElement"] {
                    guard withinBudget() else { break }
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                    var relation: [String: Any] = ["error": result.rawValue]
                    if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                        relation["nodes"] = visit(value as! AXUIElement, depth: depth + 1).map { [$0] } ?? []
                    } else if let elements = value as? [AXUIElement] {
                        relation["count"] = elements.count
                        relation["nodes"] = elements.compactMap { visit($0, depth: depth + 1) }
                    }
                    row[name] = relation
                }
                rows[index] = row
                return index
            }
            let roots = windows.compactMap { visit($0, depth: 0) }
            let observedRoots = observed.compactMap { visit($0, depth: 0) }
            var report: [String: Any] = ["pid": app.processIdentifier, "windowsError": error.rawValue,
                                 "rawWindowCount": (value as? [Any])?.count ?? -1,
                                 "applicationRole": applicationRole,
                                 "roots": roots, "observedRoots": observedRoots,
                                 "nodes": rows, "truncated": truncated]
            if let identity {
                report["identityScope"] = identity.scope
                report["identityTruncated"] = identity.exhausted
            }
            applications.append(report)
        }
        return ["schemaVersion": 1, "bundleID": bundleID,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "accessibilityTrusted": AXIsProcessTrusted(), "applications": applications,
                "note": "Read-only bounded AX structure; local node IDs are not persistent tab identities. Missing AXTabs is not evidence of no native tabs."]
    }
}
