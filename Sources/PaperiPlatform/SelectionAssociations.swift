import Foundation

struct TabSelection: Equatable {
    let group: Int
    let controls: [Int]
    let selected: Int?
    let window: UInt32
}

struct SelectionAssociationReport {
    enum Status: String { case observed, unavailable, conflict }
    struct Reset: Equatable {
        enum Reason: String { case scopeChanged, topologyChanged, captureUnavailable, selectionUnavailable, identityConflict, windowDestroyed, explicitInvalidation }
        let reason: Reason
        let group: Int
        let discardedBindings: Int
    }
    let status: Status
    let groups: [TabSelection]
    let bindings: [Int: [Int: UInt32]]
    let scopeQuarantined: Bool
    let quarantinedGroups: Set<Int>
    let resets: [Reset]
    var quarantined: Bool { scopeQuarantined || !quarantinedGroups.isEmpty }
    var unavailableGroups: Set<Int> { Set(groups.filter { $0.selected == nil }.map(\.group)) }

    var json: [String: Any] {
        ["status": status.rawValue, "quarantined": quarantined,
         "scopeQuarantined": scopeQuarantined, "quarantinedGroups": quarantinedGroups.sorted(),
         "unavailableGroups": unavailableGroups.sorted(),
         "resets": resets.map { ["reason": $0.reason.rawValue, "group": $0.group,
                                  "discardedBindings": $0.discardedBindings] as [String: Any] },
         "groups": groups.map { group in
            let known = bindings[group.group] ?? [:]
            return ["group": group.group, "controls": group.controls,
                    "bindings": known.keys.sorted().map { ["control": $0, "windowID": known[$0]!] as [String: Any] },
                    "unresolvedControls": group.controls.filter { known[$0] == nil },
                    "quarantined": quarantinedGroups.contains(group.group),
                    "selectionKnown": group.selected != nil,
                    "complete": group.selected != nil && !quarantinedGroups.contains(group.group) && known.count == group.controls.count] as [String: Any]
        }]
    }
}

/// Diagnostic candidates only. Complete bindings mean every control has been
/// observed selected; they do not classify the controls as native window tabs.
final class SelectionAssociations {
    private struct Structure: Equatable { let group: Int; let controls: [Int] }
    private var scope: String?
    private var structure: [Structure]?
    private var bindings: [Int: [Int: UInt32]] = [:]
    private var quarantined = false
    private var quarantinedGroups: Set<Int> = []
    private var pendingResets: [SelectionAssociationReport.Reset] = []

    func invalidate(reason: SelectionAssociationReport.Reset.Reason = .explicitInvalidation) {
        discard(reason: reason)
        structure = nil
    }

    // Only actual losses are recorded. Repeated invalidations before a sample
    // cannot grow this buffer because the first one removes the bindings.
    private func discard(group: Int? = nil, reason: SelectionAssociationReport.Reset.Reason) {
        for id in (group.map { [$0] } ?? bindings.keys.sorted()) {
            if let removed = bindings.removeValue(forKey: id), !removed.isEmpty {
                pendingResets.append(.init(reason: reason, group: id, discardedBindings: removed.count))
            }
        }
    }

    func observe(scope: String, groups: [TabSelection]?) -> SelectionAssociationReport {
        defer { pendingResets.removeAll() }
        guard !scope.isEmpty else { return unavailable() }
        if self.scope != scope {
            self.scope = scope
            invalidate(reason: .scopeChanged)
            quarantined = false
            quarantinedGroups.removeAll()
        }
        guard let input = groups else { return unavailable() }
        guard !quarantined else { return conflict() }
        let groups = input.sorted { $0.group < $1.group }
        let groupIDs = groups.map(\.group)
        let controls = groups.flatMap(\.controls)
        guard Set(groupIDs).count == groupIDs.count,
              Set(controls).count == controls.count,
              Set(groupIDs).isDisjoint(with: Set(controls)),
              groups.allSatisfy({ group in group.group > 0 && !group.controls.isEmpty && group.controls.allSatisfy { $0 > 0 } &&
                  (group.selected.map { group.controls.contains($0) } ?? true) && group.window > 0 }) else { return conflict() }
        let next = groups.map { Structure(group: $0.group, controls: $0.controls) }
        if structure != next {
            discard(reason: .topologyChanged)
            structure = next
        }
        for group in groups {
            guard let selected = group.selected, !quarantinedGroups.contains(group.group) else {
                discard(group: group.group, reason: group.selected == nil ? .selectionUnavailable : .identityConflict)
                continue
            }
            if let old = bindings[group.group]?[selected], old != group.window {
                quarantinedGroups.insert(group.group)
                continue
            }
            bindings[group.group, default: [:]][selected] = group.window
        }
        // Inspect every claimant before removing any: a collision must quarantine
        // both groups, independent of iteration order. Include already blocked
        // groups' current owners so another candidate cannot claim their window.
        var owners: [UInt32: [Int]] = [:]
        for group in groups {
            let known = bindings[group.group] ?? [:]
            for window in known.values { owners[window, default: []].append(group.group) }
            if group.selected.flatMap({ known[$0] }) != group.window {
                owners[group.window, default: []].append(group.group)
            }
        }
        for claimants in owners.values where claimants.count > 1 {
            quarantinedGroups.formUnion(claimants)
        }
        for group in quarantinedGroups.sorted() { discard(group: group, reason: .identityConflict) }
        let blocked = !groups.isEmpty && groups.allSatisfy { quarantinedGroups.contains($0.group) }
        let unavailable = !groups.isEmpty && groups.allSatisfy { $0.selected == nil || quarantinedGroups.contains($0.group) }
        return SelectionAssociationReport(status: blocked ? .conflict : (unavailable ? .unavailable : .observed), groups: groups,
                                          bindings: bindings, scopeQuarantined: false,
                                          quarantinedGroups: quarantinedGroups, resets: pendingResets)
    }

    private func unavailable() -> SelectionAssociationReport {
        discard(reason: .captureUnavailable)
        return SelectionAssociationReport(status: .unavailable, groups: [], bindings: [:],
                                          scopeQuarantined: quarantined, quarantinedGroups: quarantinedGroups, resets: pendingResets)
    }

    private func conflict() -> SelectionAssociationReport {
        quarantined = true
        discard(reason: .identityConflict)
        return SelectionAssociationReport(status: .conflict, groups: [], bindings: [:],
                                          scopeQuarantined: true, quarantinedGroups: quarantinedGroups, resets: pendingResets)
    }
}

enum TabSelectionEvidence {
    private static func errorCode(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? Int32).map(Int.init)
    }

    struct Issue: Equatable {
        enum Reason: String {
            case incompleteCapture, noRoots, invalidRoot, rootReferenceUnavailable, nodeRoleUnavailable, groupIdentityUnavailable
            case groupOwnerUnavailable, tabsUnavailable, controlMetadataUnavailable
            case selectionValueUnavailable, selectionAmbiguous
        }
        let reason: Reason
        var node: Int? = nil
        var attribute: String? = nil
        var error: Int? = nil

        var json: [String: Any] {
            var result: [String: Any] = ["reason": reason.rawValue]
            if let node { result["node"] = node }
            if let attribute { result["attribute"] = attribute }
            if let error { result["error"] = error }
            return result
        }
    }

    struct Capture {
        let groups: [TabSelection]?
        let issues: [Issue]
    }

    /// Complete structure and ownership are required. Missing/ambiguous selection
    /// withholds only that known group; never fill it from spare physical roots.
    static func parse(nodes: [[String: Any]], roots: [Int], complete: Bool) -> [TabSelection]? {
        inspect(nodes: nodes, roots: roots, complete: complete).groups
    }

    /// Explains the first structural rejection and every unavailable selection.
    /// Node indices refer only to this capture, never to durable AX identities.
    static func inspect(nodes: [[String: Any]], roots: [Int], complete: Bool) -> Capture {
        guard complete else { return Capture(groups: nil, issues: [.init(reason: .incompleteCapture)]) }
        guard !roots.isEmpty else { return Capture(groups: nil, issues: [.init(reason: .noRoots)]) }
        guard roots.allSatisfy({ nodes.indices.contains($0) }) else {
            return Capture(groups: nil, issues: [.init(reason: .invalidRoot)])
        }
        var result: [TabSelection] = []
        var issues: [Issue] = []
        func reject(_ reason: Issue.Reason, node: Int, attribute: String) -> Capture {
            let relation = nodes[node][attribute] as? [String: Any]
            let error = errorCode(relation?["error"]) ?? errorCode(nodes[node][attribute + "Error"])
            return Capture(groups: nil, issues: issues + [.init(reason: reason, node: node, attribute: attribute, error: error)])
        }
        func relation(_ node: [String: Any], _ name: String) -> [Int]? {
            guard let value = node[name] as? [String: Any],
                  value["error"] as? Int == 0 || value["error"] as? Int32 == 0 else { return nil }
            return value["nodes"] as? [Int]
        }
        for index in Set(roots).sorted() {
            if let validation = nodes[index]["rootValidation"] as? [String: Any],
               validation["status"] as? String != "accepted" {
                // Finder's AXWindows includes a desktop AXScrollArea alongside
                // real AXWindow documents. Non-window roots have no children
                // traversed; only unreadable or foreign/ownerless roots reject.
                if validation["reason"] as? String == WindowReferenceValidation.Rejection.nonWindowRole.rawValue,
                   let role = nodes[index]["AXRole"] as? String, !role.isEmpty {
                    continue
                }
                return Capture(groups: nil, issues: [.init(reason: .rootReferenceUnavailable, node: index)])
            }
        }
        // An unreadable role may conceal an entire tab group. A bounded graph
        // with such a node cannot affirm even an empty candidate topology.
        for (index, node) in nodes.enumerated() {
            guard let role = node["AXRole"] as? String, !role.isEmpty else {
                return reject(.nodeRoleUnavailable, node: index, attribute: "AXRole")
            }
        }
        for (index, group) in nodes.enumerated() where group["AXRole"] as? String == "AXTabGroup" {
            guard let id = group["axIdentity"] as? Int else {
                return reject(.groupIdentityUnavailable, node: index, attribute: "axIdentity")
            }
            guard let owner = relation(group, "AXWindow"), owner.count == 1,
                  let root = owner.first, roots.contains(root), nodes.indices.contains(root),
                  nodes[root]["AXRole"] as? String == "AXWindow",
                  let window = nodes[root]["windowID"] as? UInt32, window > 0 else {
                return reject(.groupOwnerUnavailable, node: index, attribute: "AXWindow")
            }
            guard let tabs = relation(group, "AXTabs"), !tabs.isEmpty,
                  let tabData = group["AXTabs"] as? [String: Any], tabData["count"] as? Int == tabs.count,
                  Set(tabs).count == tabs.count, tabs.allSatisfy({ nodes.indices.contains($0) }) else {
                return reject(.tabsUnavailable, node: index, attribute: "AXTabs")
            }
            var controls: [Int] = []
            var selected: [Int] = []
            var selectionKnown = true
            for index in tabs {
                let control = nodes[index]
                guard control["AXRole"] as? String == "AXRadioButton" else {
                    return reject(.controlMetadataUnavailable, node: index, attribute: "AXRole")
                }
                guard control["AXSubrole"] as? String == "AXTabButton" else {
                    return reject(.controlMetadataUnavailable, node: index, attribute: "AXSubrole")
                }
                guard let token = control["axIdentity"] as? Int else {
                    return reject(.controlMetadataUnavailable, node: index, attribute: "axIdentity")
                }
                guard relation(control, "AXWindow") == owner else {
                    return reject(.controlMetadataUnavailable, node: index, attribute: "AXWindow")
                }
                controls.append(token)
                if let value = control["AXValue"] as? Bool {
                    if value { selected.append(token) }
                } else {
                    selectionKnown = false
                    issues.append(.init(reason: .selectionValueUnavailable, node: index, attribute: "AXValue",
                                        error: errorCode(control["AXValueError"])))
                }
            }
            if selectionKnown && selected.count != 1 {
                issues.append(.init(reason: .selectionAmbiguous, node: index, attribute: "AXTabs"))
            }
            result.append(TabSelection(group: id, controls: controls,
                selected: selectionKnown && selected.count == 1 ? selected[0] : nil, window: window))
        }
        return Capture(groups: result, issues: issues)
    }
}
