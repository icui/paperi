import Foundation

struct TabSelection: Equatable {
    let group: Int
    let controls: [Int]
    let selected: Int
    let window: UInt32
}

struct SelectionAssociationReport {
    enum Status: String { case observed, unavailable, conflict }
    let status: Status
    let groups: [TabSelection]
    let bindings: [Int: [Int: UInt32]]

    var json: [String: Any] {
        ["status": status.rawValue, "groups": groups.map { group in
            let known = bindings[group.group] ?? [:]
            return ["group": group.group, "controls": group.controls,
                    "bindings": known.keys.sorted().map { ["control": $0, "windowID": known[$0]!] as [String: Any] },
                    "unresolvedControls": group.controls.filter { known[$0] == nil },
                    "complete": known.count == group.controls.count] as [String: Any]
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

    func invalidate() {
        bindings.removeAll()
        structure = nil
    }

    func observe(scope: String, groups: [TabSelection]?) -> SelectionAssociationReport {
        guard !scope.isEmpty else { return unavailable() }
        if self.scope != scope {
            self.scope = scope
            invalidate()
            quarantined = false
        }
        guard let input = groups else { return unavailable() }
        guard !quarantined else { return conflict() }
        let groups = input.sorted { $0.group < $1.group }
        let groupIDs = groups.map(\.group)
        let controls = groups.flatMap(\.controls)
        guard Set(groupIDs).count == groupIDs.count,
              Set(controls).count == controls.count,
              Set(groupIDs).isDisjoint(with: Set(controls)),
              groups.allSatisfy({ $0.group > 0 && !$0.controls.isEmpty && $0.controls.allSatisfy { $0 > 0 } &&
                  $0.controls.contains($0.selected) && $0.window > 0 }) else { return conflict() }
        let next = groups.map { Structure(group: $0.group, controls: $0.controls) }
        if structure != next {
            bindings.removeAll()
            structure = next
        }
        for group in groups {
            if let old = bindings[group.group]?[group.selected], old != group.window { return conflict() }
            bindings[group.group, default: [:]][group.selected] = group.window
        }
        let windows = bindings.values.flatMap { $0.values }
        guard Set(windows).count == windows.count else { return conflict() }
        return SelectionAssociationReport(status: .observed, groups: groups, bindings: bindings)
    }

    private func unavailable() -> SelectionAssociationReport {
        bindings.removeAll()
        return SelectionAssociationReport(status: .unavailable, groups: [], bindings: [:])
    }

    private func conflict() -> SelectionAssociationReport {
        quarantined = true
        bindings.removeAll()
        return SelectionAssociationReport(status: .conflict, groups: [], bindings: [:])
    }
}

enum TabSelectionEvidence {
    /// Reject partial metadata; never fill an unknown control from spare roots.
    static func parse(nodes: [[String: Any]], roots: [Int], complete: Bool) -> [TabSelection]? {
        guard complete, roots.allSatisfy({ nodes.indices.contains($0) }) else { return nil }
        var result: [TabSelection] = []
        func relation(_ node: [String: Any], _ name: String) -> [Int]? {
            guard let value = node[name] as? [String: Any],
                  value["error"] as? Int == 0 || value["error"] as? Int32 == 0 else { return nil }
            return value["nodes"] as? [Int]
        }
        for group in nodes where group["AXRole"] as? String == "AXTabGroup" {
            guard let id = group["axIdentity"] as? Int,
                  let owner = relation(group, "AXWindow"), owner.count == 1,
                  let root = owner.first, roots.contains(root), nodes.indices.contains(root),
                  nodes[root]["AXRole"] as? String == "AXWindow",
                  let window = nodes[root]["windowID"] as? UInt32, window > 0,
                  let tabs = relation(group, "AXTabs"), !tabs.isEmpty,
                  let tabData = group["AXTabs"] as? [String: Any], tabData["count"] as? Int == tabs.count,
                  Set(tabs).count == tabs.count, tabs.allSatisfy({ nodes.indices.contains($0) }) else { return nil }
            var controls: [Int] = []
            var selected: [Int] = []
            for index in tabs {
                let control = nodes[index]
                guard control["AXRole"] as? String == "AXRadioButton",
                      control["AXSubrole"] as? String == "AXTabButton",
                      let token = control["axIdentity"] as? Int,
                      let value = control["AXValue"] as? Bool,
                      relation(control, "AXWindow") == owner else { return nil }
                controls.append(token)
                if value { selected.append(token) }
            }
            guard selected.count == 1 else { return nil }
            result.append(TabSelection(group: id, controls: controls, selected: selected[0], window: window))
        }
        return result
    }
}
