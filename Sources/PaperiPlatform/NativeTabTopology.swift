import Foundation

struct NativeTabPartition: Equatable {
    let members: [UInt32]
    let active: UInt32
}

enum NativeTabTopology {
    /// Reconcile admitted members and explicitly authorized additions to their
    /// groups. Missing enumeration is never closure; only native destruction
    /// removes a physical member. Additions still require complete group evidence.
    static func inspect(_ app: [String: Any], managed: Set<UInt32>, destroyed: Set<UInt32>,
                        additions: Set<UInt32> = [], allowLazyUnvisited: Bool = false) -> [NativeTabPartition]? {
        guard app["windowsError"] as? Int32 == 0, app["truncated"] as? Bool == false,
              app["identityTruncated"] as? Bool == false,
              let nodes = app["nodes"] as? [[String: Any]], let roots = app["roots"] as? [Int],
              let observed = app["observedRoots"] as? [Int],
              let scope = app["identityScope"] as? String, !scope.isEmpty,
              let report = app["selectionAssociations"] as? [String: Any],
              report["scopeQuarantined"] as? Bool == false else { return nil }
        let remaining = managed.subtracting(destroyed)
        // An empty AX inventory cannot prove closure. Explicit destruction can.
        if remaining.isEmpty { return managed.isSubset(of: destroyed) ? [] : nil }
        guard let groups = TabSelectionEvidence.inspect(nodes: nodes, roots: roots + observed, complete: true).groups else { return nil }
        let complete = NativeTabMembership.inspect(app)
        let allowed = remaining.union(additions.subtracting(destroyed))
        // New members may join an existing group, never bootstrap an unrelated
        // application window or independent group through topology reconciliation.
        var partitions = complete.filter { Set($0.members).isSubset(of: allowed) && !Set($0.members).isDisjoint(with: remaining) }
            .map { NativeTabPartition(members: $0.members, active: $0.active) }
        var grouped = Set(partitions.flatMap(\.members))
        for root in roots {
            guard let id = nodes[root]["windowID"] as? UInt32, remaining.contains(id), !grouped.contains(id) else { continue }
            // A previously confirmed native member is detached only when its
            // full direct child list is readable and contains no tab group.
            guard !groups.contains(where: { $0.window == id }),
                  let children = nodes[root]["AXChildren"] as? [String: Any], children["error"] as? Int32 == 0,
                  let indices = children["nodes"] as? [Int], let count = children["count"] as? Int,
                  indices.count == count, indices.allSatisfy({ nodes.indices.contains($0) && nodes[$0]["AXRole"] as? String != "AXTabGroup" }) else { continue }
            partitions.append(.init(members: [id], active: id))
        }
        grouped = Set(partitions.flatMap(\.members))
        if allowLazyUnvisited, let candidates = report["groups"] as? [[String: Any]] {
            struct PartialGroup {
                let group: TabSelection
                var byControl: [Int: UInt32]
                let unresolvedControls: [Int]
            }
            let partialGroups: [PartialGroup] = groups.compactMap { group in
                guard let selected = TabSelectionEvidence.lazySelectedControl(for: group, in: nodes),
                      group.controls.count > 1,
                      allowed.contains(group.window), !grouped.contains(group.window),
                      let index = nodes.firstIndex(where: { $0["axIdentity"] as? Int == group.group }),
                      roots.contains(where: { root in
                          guard nodes[root]["windowID"] as? UInt32 == group.window,
                                let children = nodes[root]["AXChildren"] as? [String: Any],
                                children["error"] as? Int32 == 0 else { return false }
                          return (children["nodes"] as? [Int])?.contains(index) == true
                      }),
                      let candidate = candidates.first(where: { $0["group"] as? Int == group.group }),
                      candidate["quarantined"] as? Bool == false,
                      let rawBindings = candidate["bindings"] as? [[String: Any]] else { return nil }
                var byControl: [Int: UInt32] = [:]
                for binding in rawBindings {
                    guard let control = binding["control"] as? Int, group.controls.contains(control),
                          let wid = binding["windowID"] as? UInt32, wid > 0, allowed.contains(wid),
                          byControl[control] == nil, !Set(byControl.values).contains(wid) else { return nil }
                    byControl[control] = wid
                }
                if byControl[selected] == nil, !Set(byControl.values).contains(group.window) {
                    byControl[selected] = group.window
                }
                guard byControl[selected] == group.window else { return nil }
                return PartialGroup(group: group, byControl: byControl,
                                    unresolvedControls: group.controls.filter { byControl[$0] == nil })
            }
            let enumeratedWindowIDs = Set(roots.compactMap { nodes[$0]["windowID"] as? UInt32 })
            let allBoundWindows = Set(partialGroups.flatMap { $0.byControl.values })
            let hiddenRemaining = remaining.subtracting(grouped).subtracting(enumeratedWindowIDs).subtracting(allBoundWindows)
            let hiddenAdditions = additions.subtracting(destroyed).subtracting(grouped).subtracting(enumeratedWindowIDs).subtracting(allBoundWindows)
            if hiddenRemaining.isEmpty && hiddenAdditions.isEmpty {
                for entry in partialGroups {
                    let members = entry.group.controls.compactMap { entry.byControl[$0] }
                    if !members.isEmpty, Set(members).count == members.count, !Set(members).isDisjoint(with: remaining) {
                        partitions.append(.init(members: members, active: entry.group.window))
                    }
                }
            } else if partialGroups.count == 1, var entry = partialGroups.first {
                let pool = hiddenAdditions.isEmpty ? hiddenRemaining.sorted() : hiddenRemaining.union(hiddenAdditions).sorted()
                if pool.count <= entry.unresolvedControls.count {
                    for (control, wid) in zip(entry.unresolvedControls, pool) {
                        entry.byControl[control] = wid
                    }
                    let members = entry.group.controls.compactMap { entry.byControl[$0] }
                    if !members.isEmpty, Set(members).count == members.count, !Set(members).isDisjoint(with: remaining) {
                        partitions.append(.init(members: members, active: entry.group.window))
                    }
                }
            }
        }
        let all = partitions.flatMap(\.members)
        guard remaining.isSubset(of: Set(all)), Set(all).isSubset(of: allowed), Set(all).count == all.count else { return nil }
        return partitions.sorted { $0.members.min()! < $1.members.min()! }
    }
}
