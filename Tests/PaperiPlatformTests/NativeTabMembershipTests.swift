import Testing
@testable import PaperiPlatform

struct NativeTabMembershipTests {
    func application() -> [String: Any] {
        let owner: [String: Any] = ["error": Int32(0), "nodes": [0]]
        let nodes: [[String: Any]] = [
            ["AXRole": "AXWindow", "windowID": UInt32(101), "rootValidation": ["status": "accepted"],
             "AXChildren": ["error": Int32(0), "nodes": [1]]],
            ["AXRole": "AXTabGroup", "axIdentity": 1, "AXWindow": owner,
             "AXTabs": ["error": Int32(0), "count": 2, "nodes": [2, 3]]],
            ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 11,
             "AXValue": true, "AXWindow": owner],
            ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 12,
             "AXValue": false, "AXWindow": owner]
        ]
        let tracker = SelectionAssociations()
        _ = tracker.observe(scope: "test", groups: [.init(group: 1, controls: [11, 12], selected: 12, window: 102)])
        let report = tracker.observe(scope: "test", groups: [.init(group: 1, controls: [11, 12], selected: 11, window: 101)])
        return ["windowsError": Int32(0), "truncated": false, "identityTruncated": false,
                "identityScope": "test", "nodes": nodes, "roots": [0], "observedRoots": [0],
                "selectionAssociations": report.json]
    }

    @Test func completeExternalSelectionBindingsProduceOneNativeMembership() {
        #expect(NativeTabMembership.inspect(application()) == [.init(scope: "test", group: 1, members: [101, 102], active: 101)])
    }

    @Test func incompleteCaptureAndNestedContentTabsCannotPromote() {
        for key in ["truncated", "identityTruncated"] {
            var app = application(); app[key] = true
            #expect(NativeTabMembership.inspect(app).isEmpty)
        }
        var app = application()
        var nodes = app["nodes"] as! [[String: Any]]
        nodes[0]["AXChildren"] = ["error": Int32(0), "nodes": [4]]
        nodes.append(["AXRole": "AXGroup", "AXChildren": ["error": Int32(0), "nodes": [1]]])
        app["nodes"] = nodes
        #expect(NativeTabMembership.inspect(app).isEmpty)
        nodes = application()["nodes"] as! [[String: Any]]
        nodes[0]["AXChildren"] = ["error": Int32(-25202), "nodes": [1]]
        app["nodes"] = nodes
        #expect(NativeTabMembership.inspect(app).isEmpty)
    }

    @Test func partialDuplicateAndStaleBindingsCannotPromote() {
        for bindings: [[String: Any]] in [
            [["control": 11, "windowID": UInt32(101)]],
            [["control": 11, "windowID": UInt32(101)], ["control": 12, "windowID": UInt32(101)]],
            [["control": 11, "windowID": UInt32(999)], ["control": 12, "windowID": UInt32(102)]],
            [["control": 11, "windowID": UInt32(101)], ["control": 11, "windowID": UInt32(102)]]
        ] {
            var app = application()
            var report = app["selectionAssociations"] as! [String: Any]
            var groups = report["groups"] as! [[String: Any]]
            groups[0]["bindings"] = bindings; report["groups"] = groups; app["selectionAssociations"] = report
            #expect(NativeTabMembership.inspect(app).isEmpty)
        }
    }

    @Test func inactiveSpaceMayBeAbsentButMustHaveSameGroupSelectedEvidence() {
        var spaces = NativeTabMemberSpaces()
        let group = NativeTabMembership(scope: "one", group: 1, members: [101, 102], active: 101)
        spaces.observe(scope: "one", group: 1, selected: 101, space: 7)
        #expect(spaces.confirmedSpace(for: group, current: [101: 7]) == nil)
        spaces.observe(scope: "one", group: 1, selected: 102, space: 7)
        #expect(spaces.confirmedSpace(for: group, current: [101: 7]) == 7)
        #expect(spaces.confirmedSpace(for: group, current: [:]) == nil)
        #expect(spaces.confirmedSpace(for: group, current: [101: 7, 102: 8]) == nil)
        #expect(spaces.confirmedSpace(for: .init(scope: "two", group: 1, members: [101, 102], active: 101), current: [101: 7]) == nil)
        #expect(spaces.confirmedSpace(for: .init(scope: "one", group: 2, members: [101, 102], active: 101), current: [101: 7]) == nil)
        // A conflicting selected-member Space poisons that group for this run.
        spaces.observe(scope: "one", group: 1, selected: 102, space: 8)
        spaces.observe(scope: "one", group: 1, selected: 102, space: 7)
        #expect(spaces.confirmedSpace(for: group, current: [101: 7]) == nil)
    }

    @Test func singletonInspectionAcceptsTabBarFreeWindowsAndRejectsTabGroupsOrIncompleteChildren() {
        var app = application()
        var nodes = app["nodes"] as! [[String: Any]]
        nodes.append(["AXRole": "AXWindow", "windowID": UInt32(202), "rootValidation": ["status": "accepted"],
                      "AXChildren": ["error": Int32(0), "count": 1, "nodes": [5]]])
        nodes.append(["AXRole": "AXSplitGroup"])
        nodes.append(["AXRole": "AXScrollArea", "rootValidation": ["status": "unavailable", "reason": "nonWindowRole"]])
        app["nodes"] = nodes; app["roots"] = [0, 4, 6]; app["observedRoots"] = [0, 4, 6]
        #expect(NativeTabMembership.inspectSingletons(app) == [202])
        nodes[4]["AXChildren"] = ["error": Int32(0), "count": 2, "nodes": [5]]
        app["nodes"] = nodes
        #expect(NativeTabMembership.inspectSingletons(app).isEmpty)
    }
}
