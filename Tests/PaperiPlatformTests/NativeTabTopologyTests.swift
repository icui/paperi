import Testing
import PaperiCore
@testable import PaperiPlatform

struct NativeTabTopologyTests {
    func detached() -> [String: Any] {
        var app = NativeTabMembershipTests().application()
        app["nodes"] = [UInt32(101), 102].enumerated().map { index, id -> [String: Any] in
            ["node": index, "AXRole": "AXWindow", "windowID": id,
             "rootValidation": ["status": "accepted"],
             "AXChildren": ["error": Int32(0), "count": 0, "nodes": [Int]()]]
        }
        app["roots"] = [0, 1]; app["observedRoots"] = [0, 1]
        return app
    }

    @Test func knownMembersDetachButMissingEnumerationDoesNotClose() {
        var app = detached()
        #expect(NativeTabTopology.inspect(app, managed: [101, 102], destroyed: []) == [
            .init(members: [101], active: 101), .init(members: [102], active: 102)])
        app["roots"] = [0]
        #expect(NativeTabTopology.inspect(app, managed: [101, 102], destroyed: []) == nil)
        #expect(NativeTabTopology.inspect(app, managed: [101, 102], destroyed: [102]) == [.init(members: [101], active: 101)])
        #expect(NativeTabTopology.inspect(app, managed: [101, 102], destroyed: [101, 102]) == [])
    }

    @Test func regroupingRequiresCompleteBindingsAndCannotAbsorbUnknownMembers() {
        var app = NativeTabMembershipTests().application()
        #expect(NativeTabTopology.inspect(app, managed: [101, 102], destroyed: []) == [.init(members: [101, 102], active: 101)])
        #expect(NativeTabTopology.inspect(app, managed: [101], destroyed: []) == nil)
        app["selectionAssociations"] = ["scopeQuarantined": false, "groups": [[String: Any]]()]
        #expect(NativeTabTopology.inspect(app, managed: [101, 102], destroyed: []) == nil)
        app = detached(); app["truncated"] = true
        #expect(NativeTabTopology.inspect(app, managed: [101, 102], destroyed: []) == nil)
    }

    @Test func additionsRequireExplicitAuthorizationAndAnExistingGroupAnchor() {
        let app = NativeTabMembershipTests().application()
        #expect(NativeTabTopology.inspect(app, managed: [101], destroyed: []) == nil)
        #expect(NativeTabTopology.inspect(app, managed: [101], destroyed: [], additions: [102]) == [
            .init(members: [101, 102], active: 101)])
        #expect(NativeTabTopology.inspect(app, managed: [999], destroyed: [], additions: [101, 102]) == nil)
        #expect(NativeTabTopology.inspect(app, managed: [101], destroyed: [102], additions: [102]) == nil)
        var partial = app
        partial["selectionAssociations"] = ["scopeQuarantined": false, "groups": [[String: Any]]()]
        #expect(NativeTabTopology.inspect(partial, managed: [101], destroyed: [], additions: [102]) == nil)
    }

    @MainActor @Test func admittedGrowthPreservesSlotWidthAndRejectsUnknownOrIndependentAdditions() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: Rect(x: 0, y: 0, width: 1000, height: 600))
        let eligible = WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow",
            isRoot: true, movable: true, resizable: true, level: 0))
        let ticket = session.ticket
        try session.admitTabs(members: [1, 2], active: 1, ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        let original = session.state
        let slot = session.slots[1]
        let grown = [NativeTabPartition(members: [1, 2, 3], active: 3)]
        #expect(try !session.reconcileTabs(grown, destroyed: [], ownerPID: 42, spaceID: 7,
                                          classification: eligible, ticket: ticket))
        #expect(session.state == original && session.slots[3] == nil)
        #expect(try !session.reconcileTabs([.init(members: [1, 2], active: 1), .init(members: [3], active: 3)],
            destroyed: [], ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket, admitted: [3]))
        #expect(session.state == original)
        #expect(try session.reconcileTabs(grown, destroyed: [], ownerPID: 42, spaceID: 7,
                                         classification: eligible, ticket: ticket, admitted: [3]))
        #expect(session.slots[3] == slot && session.state.layout.columns.count == 1)
        #expect(session.state.layout.columns[0].width == original.layout.columns[0].width)
        try session.reconcileTabs([.init(members: [1, 2], active: 1)], destroyed: [3], ownerPID: 42, spaceID: 7,
                                  classification: eligible, ticket: ticket)
        #expect(session.slots[1] == slot && session.slots[3] == nil)
    }

    @MainActor @Test func detachMergeAndActiveClosureKeepCorrectSlotAndWidth() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: Rect(x: 0, y: 0, width: 1000, height: 600))
        let eligible = WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow",
            isRoot: true, movable: true, resizable: true, level: 0))
        let ticket = session.ticket
        try session.admitTabs(members: [1, 2], active: 2, ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        let original = session.slots[2]
        let width = session.state.layout.columns[0].width
        try session.reconcileTabs([.init(members: [1], active: 1), .init(members: [2], active: 2)], destroyed: [],
            ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        #expect(session.slots[2] == original && session.slots[1] != original)
        #expect(session.state.layout.columns[0].slots[0].id == original)
        try session.reconcileTabs([.init(members: [1, 2], active: 2)], destroyed: [],
            ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        #expect(session.slots[1] == original && session.slots[2] == original)
        #expect(session.state.layout.columns.count == 1 && session.state.layout.columns[0].width == width)
        try session.reconcileTabs([.init(members: [1], active: 1)], destroyed: [2],
            ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        #expect(session.slots[1] == original && session.slots[2] == nil)
        try session.reconcileTabs([], destroyed: [1], ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        #expect(session.slots.isEmpty && session.state.layout.columns.isEmpty)
    }

    @MainActor @Test func unprovenRepartitionIsTransactionalAndSuppressedFocusStaysSuppressed() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: Rect(x: 0, y: 0, width: 1000, height: 600))
        let eligible = WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow",
            isRoot: true, movable: true, resizable: true, level: 0))
        let ticket = session.ticket
        try session.admitTabs(members: [1, 2], active: 1, ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        let before = session.state
        #expect(try !session.reconcileTabs([.init(members: [1], active: 1)], destroyed: [],
            ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.state == before && session.slots.count == 2)
        #expect(try !session.reconcileTabs([.init(members: [1, 2, 3], active: 1)], destroyed: [],
            ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket))
        try session.focus(windowID: nil, ownerPID: nil, classification: eligible, ticket: ticket)
        try session.reconcileTabs([.init(members: [1], active: 1), .init(members: [2], active: 2)], destroyed: [],
            ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        #expect(session.state.interactionSuppressed)
        #expect(try !session.resizeFocused(by: 0.1, frontmostPID: 42, ticket: ticket))
    }

    @MainActor @Test func stackedColumnReconcilesSwitchDetachRemergeGrowthAndClosureWhilePreservingSiblingRow() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: Rect(x: 0, y: 0, width: 1000, height: 600),
                                          ownership: .applicationLocalFixture)
        let eligible = WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow",
            isRoot: true, movable: true, resizable: true, level: 0))
        let ticket = session.ticket
        try session.admitTabs(members: [1, 2], active: 1, ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket)
        try session.insert(windowID: 10, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket)
        let topSlot = session.slots[1]!
        let bottomSlot = session.slots[10]!
        try session.focus(windowID: 10, ownerPID: 42, classification: eligible, ticket: ticket)
        #expect(try session.slurpFocused(frontmostPID: 42, ticket: ticket))
        #expect(session.state.layout.columns.count == 1 && session.state.layout.columns[0].slots.map(\.id) == [topSlot, bottomSlot])
        // Switch active tab inside the stacked top row.
        #expect(try session.reconcileTabs([.init(members: [1, 2], active: 2), .init(members: [10], active: 10)],
            destroyed: [], ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.state.layout.columns.count == 1 && session.state.layout.columns[0].slots.map(\.id) == [topSlot, bottomSlot])
        #expect(session.state.layout.columns[0].slots[0].activeMember == 2)
        // Detach member 1 from the top stacked slot: active member 2 stays stacked with 10; 1 becomes an adjacent column.
        #expect(try session.reconcileTabs([.init(members: [1], active: 1), .init(members: [2], active: 2), .init(members: [10], active: 10)],
            destroyed: [], ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.state.layout.columns.count == 2)
        #expect(session.state.layout.columns[0].slots.map(\.id) == [topSlot, bottomSlot])
        #expect(session.state.layout.columns[1].slots.count == 1 && session.slots[1] != topSlot)
        // Re-merge 1 and 2 with 2 active, plus admit new member 3: returns to the single two-row stacked column.
        #expect(try session.reconcileTabs([.init(members: [1, 2, 3], active: 2), .init(members: [10], active: 10)],
            destroyed: [], ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket, admitted: [3]))
        #expect(session.state.layout.columns.count == 1 && session.state.layout.columns[0].slots.map(\.id) == [topSlot, bottomSlot])
        #expect(session.slots[3] == topSlot)
        // Close all three members of the top tab group; bottom sibling survives in the column.
        #expect(try session.reconcileTabs([.init(members: [10], active: 10)],
            destroyed: [1, 2, 3], ownerPID: 42, spaceID: 7, classification: eligible, ticket: ticket))
        #expect(session.state.layout.columns.count == 1 && session.state.layout.columns[0].slots.map(\.id) == [bottomSlot])
    }

    @MainActor @Test func lazyUnvisitedTabsTileImmediatelySwitchOnClickAndInferMergedKnownWindows() throws {
        let session = ScopedLayoutSession(ownerPID: 42, canvas: Rect(x: 0, y: 0, width: 1000, height: 600))
        let eligible = WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow",
            isRoot: true, movable: true, resizable: true, level: 0))
        let ticket = session.ticket

        // Window 101 has 3 tabs (controls 11, 12, 13), but only tab 11 (101) has ever been visited.
        let owner0: [String: Any] = ["error": Int32(0), "nodes": [0]]
        func makeThreeTabApp(activeWindow: UInt32, selectedControl: Int, tracker: SelectionAssociations) -> [String: Any] {
            let nodes: [[String: Any]] = [
                ["AXRole": "AXWindow", "windowID": activeWindow, "rootValidation": ["status": "accepted"],
                 "AXChildren": ["error": Int32(0), "nodes": [1]]],
                ["AXRole": "AXTabGroup", "axIdentity": 1, "AXWindow": owner0,
                 "AXTabs": ["error": Int32(0), "count": 3, "nodes": [2, 3, 4]]],
                ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 11,
                 "AXValue": selectedControl == 11, "AXWindow": owner0],
                ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 12,
                 "AXValue": selectedControl == 12, "AXWindow": owner0],
                ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 13,
                 "AXValue": selectedControl == 13, "AXWindow": owner0]
            ]
            let report = tracker.observe(scope: "test", groups: [
                .init(group: 1, controls: [11, 12, 13], selected: selectedControl, window: activeWindow)
            ])
            return ["windowsError": Int32(0), "truncated": false, "identityTruncated": false,
                    "identityScope": "test", "nodes": nodes, "roots": [0], "observedRoots": [0],
                    "selectionAssociations": report.json]
        }

        let tracker = SelectionAssociations()
        let initialApp = makeThreeTabApp(activeWindow: 101, selectedControl: 11, tracker: tracker)
        let activeGroups = NativeTabMembership.inspect(initialApp, requireComplete: false)
        #expect(activeGroups == [.init(scope: "test", group: 1, members: [101], active: 101)])

        // Admit and tile 101 immediately without waiting for tabs 12 or 13 to be clicked.
        #expect(try session.admitTabs(members: [101], active: 101, ownerPID: 42, spaceID: 7,
                                      classification: eligible, ticket: ticket, allowActiveOnly: true))
        let slotID = session.slots[101]!

        // Clicking tab 12 reveals window 102 while tab 13 remains unvisited; slot updates in place.
        let switchedApp = makeThreeTabApp(activeWindow: 102, selectedControl: 12, tracker: tracker)
        #expect(NativeTabTopology.inspect(switchedApp, managed: [101], destroyed: [], additions: [102]) == nil)
        let lazySwitched = NativeTabTopology.inspect(switchedApp, managed: [101], destroyed: [],
                                                     additions: [102], allowLazyUnvisited: true)
        #expect(lazySwitched == [.init(members: [101, 102], active: 102)])
        #expect(try session.reconcileTabs(lazySwitched!, destroyed: [], ownerPID: 42, spaceID: 7,
                                          classification: eligible, ticket: ticket, admitted: [102]))
        #expect(session.slots[101] == slotID && session.slots[102] == slotID)
        #expect(session.state.layout.columns.count == 1 && session.state.layout.columns[0].slots[0].activeMember == 102)

        // Merging an already-managed window 103 into the unvisited 3rd tab (control 13) infers 103 without clicking tab 13.
        try session.insert(windowID: 103, ownerPID: 42, spaceID: 7, classification: eligible, knownSingleton: true, ticket: ticket)
        #expect(session.state.layout.columns.count == 2)
        let inferredMerge = NativeTabTopology.inspect(switchedApp, managed: [101, 102, 103], destroyed: [],
                                                      allowLazyUnvisited: true)
        #expect(inferredMerge == [.init(members: [101, 102, 103], active: 102)])
        #expect(try session.reconcileTabs(inferredMerge!, destroyed: [], ownerPID: 42, spaceID: 7,
                                          classification: eligible, ticket: ticket))
        #expect(session.state.layout.columns.count == 1 && session.slots[103] == slotID)

        // When AppKit omits AXValue (-25200) on an unvisited tab button, lazySelectedControl still resolves the single true tab.
        var missingUnvisitedValue = initialApp
        var nodes = missingUnvisitedValue["nodes"] as! [[String: Any]]
        nodes[3].removeValue(forKey: "AXValue"); nodes[3]["AXValueError"] = Int32(-25200)
        nodes[4].removeValue(forKey: "AXValue"); nodes[4]["AXValueError"] = Int32(-25200)
        missingUnvisitedValue["nodes"] = nodes
        let emptyReport = SelectionAssociations().observe(scope: "test", groups: [
            .init(group: 1, controls: [11, 12, 13], selected: nil, window: 101)
        ])
        missingUnvisitedValue["selectionAssociations"] = emptyReport.json
        #expect(NativeTabMembership.inspect(missingUnvisitedValue, requireComplete: false) == [
            .init(scope: "test", group: 1, members: [101], active: 101)
        ])
        #expect(NativeTabTopology.inspect(missingUnvisitedValue, managed: [101, 102, 103], destroyed: [],
                                          allowLazyUnvisited: true) == [.init(members: [101, 102, 103], active: 101)])
    }
}
