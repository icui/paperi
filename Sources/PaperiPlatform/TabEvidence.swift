import AppKit
import ApplicationServices
import PaperiBridge

enum TabSelectionValue {
    static func read(_ value: CFTypeRef, role: String?, attribute: String) -> (value: Bool, encoding: String)? {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return (CFBooleanGetValue((value as! CFBoolean)), "boolean")
        }
        if attribute == "AXValue", role == "AXRadioButton", CFGetTypeID(value) == CFNumberGetTypeID(),
           let number = value as? NSNumber, number.doubleValue == 0 || number.doubleValue == 1 {
            return (number.doubleValue == 1, "number01")
        }
        return nil
    }
}

extension Diagnostics {
    /// Bounded structural evidence only: no labels, titles, descriptions or
    /// string values. Local node IDs are meaningful within this capture only.
    @MainActor public static func tabEvidence(bundleID: String) -> [String: Any] {
        tabEvidence(bundleID: bundleID, observedWindows: [:])
    }

    @MainActor static func tabEvidence(bundleID: String, observedWindows: [pid_t: [AXUIElement]],
                                      identities: [pid_t: EvidenceIdentities] = [:],
                                      associations: [pid_t: SelectionAssociations] = [:]) -> [String: Any] {
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
            var truncationReasons: Set<String> = []
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            func withinBudget() -> Bool {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    truncated = true
                    truncationReasons.insert("timeBudget")
                    return false
                }
                return true
            }
            func visit(_ element: AXUIElement, depth: Int) -> Int? {
                if let index = nodes.firstIndex(where: { CFEqual($0, element) }) { return index }
                guard depth <= 5 else {
                    truncated = true
                    truncationReasons.insert("depthLimit")
                    return nil
                }
                guard nodes.count < 128 else {
                    truncated = true
                    truncationReasons.insert("nodeLimit")
                    return nil
                }
                guard withinBudget() else { return nil }
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
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                    row[name + "Error"] = result.rawValue
                    if result == .success, let value = value as? String { row[name] = value }
                }
                if row["enumeratedWindowIndex"] != nil || row["observedWindowIndex"] != nil {
                    var owner: pid_t = 0
                    let result = AXUIElementGetPid(element, &owner)
                    var validation: [String: Any] = ["pidError": result.rawValue, "status": "accepted"]
                    if let rejection = WindowReferenceValidation.rejection(
                        pid: result == .success ? owner : nil, role: row[kAXRoleAttribute] as? String,
                        expectedPID: app.processIdentifier) {
                        validation["status"] = "unavailable"
                        validation["reason"] = rejection.rawValue
                        row["rootValidation"] = validation
                        // Preserve the rejected root itself, but do not walk an
                        // application/menu tree or an invalid/foreign reference.
                        rows[index] = row
                        return index
                    }
                    row["rootValidation"] = validation
                }
                for name in ["AXSelected", "AXValue"] {
                    guard withinBudget() else { break }
                    if name == "AXValue", row[kAXRoleAttribute] as? String != "AXRadioButton" { continue }
                    var value: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                    row[name + "Error"] = result.rawValue
                    if result == .success, let value,
                       let selection = TabSelectionValue.read(value, role: row[kAXRoleAttribute] as? String, attribute: name) {
                        row[name] = selection.value
                        row[name + "Encoding"] = selection.encoding
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
            let allRoots = Set(roots + observedRoots)
            let usableRoots = allRoots.filter { index in
                (rows[index]["rootValidation"] as? [String: Any])?["status"] as? String == "accepted" &&
                    rows[index]["AXRole"] as? String == "AXWindow" && (rows[index]["windowID"] as? UInt32 ?? 0) > 0
            }
            let rootValidations: [[String: Any]] = allRoots.sorted().map { index in
                var facts = rows[index]["rootValidation"] as? [String: Any] ?? ["status": "unavailable", "reason": "notRead"]
                facts["node"] = index
                if let role = rows[index]["AXRole"] { facts["role"] = role }
                if let error = rows[index]["AXRoleError"] { facts["roleError"] = error }
                return facts
            }
            let coverage = WindowCoverage(rootCount: allRoots.count, usableRootCount: usableRoots.count, truncated: truncated)
            var report: [String: Any] = ["pid": app.processIdentifier, "windowsError": error.rawValue,
                                 "rawWindowCount": (value as? [Any])?.count ?? -1,
                                 "applicationRole": applicationRole,
                                 "roots": roots, "observedRoots": observedRoots,
                                 "rootValidations": rootValidations,
                                 "nodes": rows, "truncated": truncated,
                                 "truncationReasons": truncationReasons.sorted(), "windowCoverage": coverage.json]
            if let identity {
                report["identityScope"] = identity.scope
                report["identityTruncated"] = identity.exhausted
                if let tracker = associations[app.processIdentifier] {
                    let capture = TabSelectionEvidence.inspect(nodes: rows, roots: roots + observedRoots,
                        complete: coverage.status == .referencesAvailable && !identity.exhausted)
                    var association = tracker.observe(scope: identity.scope, groups: capture.groups).json
                    association["evidenceIssues"] = capture.issues.map(\.json)
                    report["selectionAssociations"] = association
                }
            }
            applications.append(report)
        }
        return ["schemaVersion": 1, "bundleID": bundleID,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "accessibilityTrusted": AXIsProcessTrusted(), "applications": applications,
                "note": "Read-only bounded AX structure; local node IDs are not persistent tab identities. Missing AXTabs is not evidence of no native tabs."]
    }
}
