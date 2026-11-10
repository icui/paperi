import Foundation

/// A complete, selection-learned window group from the external AX stream.
/// It still requires fresh per-member PID, policy and Space validation before
/// admission or effects. No application names or fixture ground truth are used.
struct NativeTabMembership: Equatable {
    let scope: String
    let group: Int
    let members: [UInt32]
    let active: UInt32

    static func inspect(_ application: [String: Any]) -> [Self] {
        inspect(application, requireComplete: true)
    }

    static func inspect(_ application: [String: Any], requireComplete: Bool) -> [Self] {
        guard application["windowsError"] as? Int32 == 0,
              application["truncated"] as? Bool == false,
              application["identityTruncated"] as? Bool == false,
              let scope = application["identityScope"] as? String, !scope.isEmpty,
              let nodes = application["nodes"] as? [[String: Any]],
              let roots = application["roots"] as? [Int],
              let observed = application["observedRoots"] as? [Int],
              let report = application["selectionAssociations"] as? [String: Any],
              report["scopeQuarantined"] as? Bool == false,
              let candidates = report["groups"] as? [[String: Any]] else { return [] }
        let capture = TabSelectionEvidence.inspect(nodes: nodes, roots: roots + observed, complete: true)
        guard let groups = capture.groups else { return [] }
        return groups.compactMap { group in
            guard let selected = group.selected,
                  group.controls.count > 1,
                  let index = nodes.firstIndex(where: { $0["axIdentity"] as? Int == group.group }),
                  // Native AppKit window tabs are direct children. Nested
                  // document-content tabs are outside this adapter's scope.
                  roots.contains(where: { root in
                      guard nodes[root]["windowID"] as? UInt32 == group.window else { return false }
                      guard let children = nodes[root]["AXChildren"] as? [String: Any],
                            children["error"] as? Int32 == 0 else { return false }
                      return (children["nodes"] as? [Int])?.contains(index) == true
                  }),
                  let candidate = candidates.first(where: { $0["group"] as? Int == group.group }),
                  !requireComplete || (candidate["complete"] as? Bool == true),
                  candidate["quarantined"] as? Bool == false,
                  let bindings = candidate["bindings"] as? [[String: Any]],
                  requireComplete ? (bindings.count == group.controls.count && bindings.count > 1) : !bindings.isEmpty else { return nil }
            var byControl: [Int: UInt32] = [:]
            for binding in bindings {
                guard let control = binding["control"] as? Int, group.controls.contains(control),
                      let window = binding["windowID"] as? UInt32, window > 0,
                      byControl[control] == nil else { return nil }
                byControl[control] = window
            }
            let members = group.controls.compactMap { byControl[$0] }
            guard Set(members).count == members.count,
                  members.count == byControl.count,
                  byControl[selected] == group.window else { return nil }
            return Self(scope: scope, group: group.group, members: members, active: group.window)
        }
    }

    /// Returns freshly enumerated `AXWindow` IDs whose full direct child list was
    /// read without error and contains no `AXTabGroup`. Any capture truncation,
    /// unreadable root/role, or existing tab group for that window withholds the
    /// singleton claim.
    static func inspectSingletons(_ application: [String: Any]) -> [UInt32] {
        guard application["windowsError"] as? Int32 == 0,
              application["truncated"] as? Bool == false,
              application["identityTruncated"] as? Bool == false,
              let nodes = application["nodes"] as? [[String: Any]],
              let roots = application["roots"] as? [Int],
              let observed = application["observedRoots"] as? [Int],
              let groups = TabSelectionEvidence.inspect(nodes: nodes, roots: roots + observed, complete: true).groups else { return [] }
        let grouped = Set(groups.map(\.window)).union(inspect(application).flatMap(\.members))
        var singletons: Set<UInt32> = []
        for root in roots {
            guard nodes.indices.contains(root),
                  nodes[root]["AXRole"] as? String == "AXWindow",
                  (nodes[root]["rootValidation"] as? [String: Any])?["status"] as? String == "accepted",
                  let id = nodes[root]["windowID"] as? UInt32, id > 0, !grouped.contains(id),
                  let children = nodes[root]["AXChildren"] as? [String: Any],
                  children["error"] as? Int32 == 0 || children["error"] as? Int == 0,
                  let indices = children["nodes"] as? [Int], let count = children["count"] as? Int,
                  indices.count == count,
                  indices.allSatisfy({ nodes.indices.contains($0) && nodes[$0]["AXRole"] as? String != "AXTabGroup" }) else { continue }
            singletons.insert(id)
        }
        return singletons.sorted()
    }
}

/// Inactive AppKit members may have no window-server Space entry. Record their
/// validated Space while selected, under exactly the AX group/scope that learned
/// their identity. The active representative must still be validated freshly.
struct NativeTabMemberSpaces {
    private struct Key: Hashable { let scope: String; let group: Int }
    private var observations: [Key: [UInt32: UInt64]] = [:]
    private var conflicts: Set<Key> = []

    mutating func observe(scope: String, group: Int, selected: UInt32, space: UInt64) {
        guard !scope.isEmpty, group > 0, selected > 0, space > 0 else { return }
        let key = Key(scope: scope, group: group)
        if let prior = observations[key]?[selected], prior != space { conflicts.insert(key) }
        observations[key, default: [:]][selected] = space
    }

    func confirmedSpace(for membership: NativeTabMembership, current: [UInt32: UInt64]) -> UInt64? {
        let key = Key(scope: membership.scope, group: membership.group)
        guard !conflicts.contains(key), let known = observations[key],
              let activeSpace = current[membership.active], activeSpace > 0,
              membership.members.allSatisfy({ known[$0] == activeSpace && (current[$0] == nil || current[$0] == activeSpace) }) else { return nil }
        return activeSpace
    }
}
