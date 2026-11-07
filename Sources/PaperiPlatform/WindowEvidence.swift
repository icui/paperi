import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

extension Diagnostics {
    /// Bounded policy evidence for one app. Reads metadata, never text or geometry.
    @MainActor public static func windowEvidence(bundleID: String) -> [String: Any] {
        windowEvidence(bundleID: bundleID, observedWindows: [:])
    }

    @MainActor static func windowEvidence(bundleID: String, observedWindows: [pid_t: [AXUIElement]]) -> [String: Any] {
        let cg = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var levels: [UInt32: Int] = [:]
        for row in cg {
            if let id = row[kCGWindowNumber as String] as? UInt32, let level = row[kCGWindowLayer as String] as? Int {
                levels[id] = level
            }
        }
        var applications: [[String: Any]] = []
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            let deadline = ProcessInfo.processInfo.systemUptime + 0.75
            var truncated = false
            var errors: [String: Int32] = [:]
            func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                guard ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return nil }
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                errors[name] = result.rawValue
                return result == .success ? value : nil
            }
            let enumerated = read(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let enumerationError = errors[kAXWindowsAttribute]
            let observed = observedWindows[app.processIdentifier] ?? []
            let focused = read(application, kAXFocusedWindowAttribute)
            let focusedUI = read(application, kAXFocusedUIElementAttribute)
            let applicationErrors = errors
            var focus: [String: Any] = [:]
            if let focusedUI, CFGetTypeID(focusedUI) == AXUIElementGetTypeID() {
                let element = focusedUI as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.15)
                focus["role"] = read(element, kAXRoleAttribute) as? String
                focus["subrole"] = read(element, kAXSubroleAttribute) as? String
                if let owner = read(element, kAXWindowAttribute), CFGetTypeID(owner) == AXUIElementGetTypeID() {
                    focus["windowID"] = paperi_window_id((owner as! AXUIElement))
                }
            }
            var elements: [AXUIElement] = []
            var rows: [[String: Any]] = []
            func visit(_ element: AXUIElement, depth: Int) -> Int? {
                if let index = elements.firstIndex(where: { CFEqual($0, element) }) { return index }
                guard depth <= 2, elements.count < 32, ProcessInfo.processInfo.systemUptime < deadline else {
                    truncated = true; return nil
                }
                let index = elements.count
                elements.append(element)
                rows.append([:])
                AXUIElementSetMessagingTimeout(element, 0.15)
                errors.removeAll()
                let id = paperi_window_id(element)
                let role = read(element, kAXRoleAttribute) as? String
                let subrole = read(element, kAXSubroleAttribute) as? String
                let parent = read(element, kAXParentAttribute)
                var movable = DarwinBoolean(false), resizable = DarwinBoolean(false)
                func capability(_ name: String, _ value: inout DarwinBoolean) -> Bool? {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return nil }
                    let result = AXUIElementIsAttributeSettable(element, name as CFString, &value)
                    errors[name] = result.rawValue
                    return result == .success ? value.boolValue : nil
                }
                let move = capability(kAXPositionAttribute, &movable)
                let resize = capability(kAXSizeAttribute, &resizable)
                let fullscreen = read(element, "AXFullScreen") as? Bool
                let minimized = read(element, kAXMinimizedAttribute) as? Bool
                let facts = WindowFacts(bundleID: bundleID, role: role, subrole: subrole,
                    isRoot: parent.map { CFEqual($0, application) }, movable: move, resizable: resize,
                    fullscreen: fullscreen, minimized: minimized, level: levels[id])
                let classification = WindowPolicy.classify(facts)
                var row: [String: Any] = ["node": index, "windowID": id,
                    "eligibility": classification.eligibility.rawValue, "reason": classification.reason,
                    "enumerated": enumerated.contains { CFEqual($0, element) },
                    "observed": observed.contains { CFEqual($0, element) },
                    "focused": focused.map { CFEqual($0, element) } ?? false,
                    "queryErrors": errors]
                if let data = try? JSONEncoder().encode(facts), let json = try? JSONSerialization.jsonObject(with: data) {
                    row["facts"] = json
                }
                let children = read(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                var childWindows: [Int] = []
                if children.count > 128 { truncated = true }
                for child in children.prefix(128) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; break }
                    AXUIElementSetMessagingTimeout(child, 0.15)
                    if let role = read(child, kAXRoleAttribute) as? String, ["AXWindow", "AXSheet", "AXDialog"].contains(role),
                       let childIndex = visit(child, depth: depth + 1) { childWindows.append(childIndex) }
                }
                row["childWindows"] = childWindows
                rows[index] = row
                return index
            }
            let roots = (enumerated + observed).compactMap { visit($0, depth: 0) }
            let uniqueRoots = Set(roots)
            let usableRoots = uniqueRoots.filter { index in
                let role = (rows[index]["facts"] as? [String: Any])?["role"] as? String
                return (role == "AXWindow" || role == "AXSheet") && (rows[index]["windowID"] as? UInt32 ?? 0) > 0
            }
            let coverage = WindowCoverage(rootCount: uniqueRoots.count, usableRootCount: usableRoots.count, truncated: truncated)
            var report: [String: Any] = ["pid": app.processIdentifier, "applicationActive": app.isActive,
                "windowsError": enumerationError.map { $0 as Any } ?? NSNull(),
                "roots": uniqueRoots.sorted(), "windows": rows, "focusedUI": focus,
                "truncated": truncated, "windowCoverage": coverage.json]
            report["applicationQueryErrors"] = applicationErrors
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                report["focusedWindowID"] = paperi_window_id((focused as! AXUIElement))
            }
            applications.append(report)
        }
        return ["schemaVersion": 1, "bundleID": bundleID, "accessibilityTrusted": AXIsProcessTrusted(),
                "applications": applications, "note": "Read-only bounded policy evidence. Missing metadata is unknown; absent windows are not closure."]
    }
}
