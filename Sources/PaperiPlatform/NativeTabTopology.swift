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
                        additions: Set<UInt32> = []) -> [NativeTabPartition]? {
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
        let grouped = Set(partitions.flatMap(\.members))
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
        let all = partitions.flatMap(\.members)
        guard remaining.isSubset(of: Set(all)), Set(all).isSubset(of: allowed), Set(all).count == all.count else { return nil }
        return partitions.sorted { $0.members.min()! < $1.members.min()! }
    }
}
