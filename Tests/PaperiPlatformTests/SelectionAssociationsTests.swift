import ApplicationServices
import Testing
@testable import PaperiPlatform

struct SelectionAssociationsTests {
    private func selection(_ selected: Int = 11, window: UInt32 = 101,
                           controls: [Int] = [11, 12], group: Int = 1) -> TabSelection {
        TabSelection(group: group, controls: controls, selected: selected, window: window)
    }

    @Test func resetEvidenceExplainsLossWithoutRepeatingOrClearingOtherGroups() {
        let tracker = SelectionAssociations()
        let other = selection(21, window: 201, controls: [21, 22], group: 2)
        #expect(tracker.observe(scope: "one", groups: [selection(), other]).resets.isEmpty)
        _ = tracker.observe(scope: "one", groups: [selection(12, window: 102), other])
        let unknown = TabSelection(group: 1, controls: [11, 12], selected: nil, window: 102)
        let lost = tracker.observe(scope: "one", groups: [unknown, other])
        #expect(lost.resets == [.init(reason: .selectionUnavailable, group: 1, discardedBindings: 2)])
        #expect(lost.bindings == [2: [21: 201]])
        #expect(tracker.observe(scope: "one", groups: [unknown, other]).resets.isEmpty)
        let missing = tracker.observe(scope: "one", groups: nil)
        #expect(missing.resets == [.init(reason: .captureUnavailable, group: 2, discardedBindings: 1)])
        #expect(tracker.observe(scope: "one", groups: nil).resets.isEmpty)
    }

    @Test func resetEvidenceSurvivesDestructionUntilNextReportAndDistinguishesScopeTopologyConflict() {
        let tracker = SelectionAssociations()
        _ = tracker.observe(scope: "one", groups: [selection()])
        tracker.invalidate(reason: .windowDestroyed)
        tracker.invalidate(reason: .windowDestroyed)
        let destroyed = tracker.observe(scope: "two", groups: [selection()])
        #expect(destroyed.resets == [.init(reason: .windowDestroyed, group: 1, discardedBindings: 1)])
        let topology = tracker.observe(scope: "two", groups: [selection(controls: [11])])
        #expect(topology.resets == [.init(reason: .topologyChanged, group: 1, discardedBindings: 1)])
        let scope = tracker.observe(scope: "three", groups: [selection(controls: [11])])
        #expect(scope.resets == [.init(reason: .scopeChanged, group: 1, discardedBindings: 1)])
        let conflict = tracker.observe(scope: "three", groups: [selection(window: 999, controls: [11])])
        #expect(conflict.resets == [.init(reason: .identityConflict, group: 1, discardedBindings: 1)])
        #expect((conflict.json["resets"] as? [[String: Any]])?.first?["reason"] as? String == "identityConflict")
        #expect(tracker.observe(scope: "three", groups: [selection(controls: [11])]).resets.isEmpty)
    }

    @Test func unvisitedControlsStayUnresolvedUntilSelected() {
        let tracker = SelectionAssociations()
        let first = tracker.observe(scope: "one", groups: [selection()])
        #expect(first.status == .observed)
        #expect(first.bindings == [1: [11: 101]])
        let second = tracker.observe(scope: "one", groups: [selection(12, window: 102)])
        #expect(second.bindings == [1: [11: 101, 12: 102]])
        #expect(tracker.observe(scope: "one", groups: [selection()]).bindings == second.bindings)
    }

    @Test func topologyOrderScopeAndDestructionDiscardLearnedBindings() {
        let tracker = SelectionAssociations()
        _ = tracker.observe(scope: "one", groups: [selection()])
        _ = tracker.observe(scope: "one", groups: [selection(12, window: 102)])
        let regrouped = tracker.observe(scope: "one", groups: [selection(12, window: 102, controls: [11, 12, 13])])
        #expect(regrouped.bindings == [1: [12: 102]])
        let reordered = tracker.observe(scope: "one", groups: [selection(11, controls: [13, 12, 11])])
        #expect(reordered.bindings == [1: [11: 101]])
        let replacement = tracker.observe(scope: "two", groups: [selection(12, window: 202, controls: [13, 12, 11])])
        #expect(replacement.bindings == [1: [12: 202]])
        tracker.invalidate()
        #expect(tracker.observe(scope: "two", groups: [selection()]).bindings == [1: [11: 101]])
    }

    @Test func incompleteEvidenceAndDisappearanceNeverReplayBindings() {
        let tracker = SelectionAssociations()
        _ = tracker.observe(scope: "one", groups: [selection()])
        #expect(tracker.observe(scope: "one", groups: nil).status == .unavailable)
        #expect(tracker.observe(scope: "one", groups: [selection(12, window: 102)]).bindings == [1: [12: 102]])
        #expect(tracker.observe(scope: "one", groups: []).groups.isEmpty)
        #expect(tracker.observe(scope: "one", groups: [selection()]).bindings == [1: [11: 101]])
    }

    @Test func conflictingIdentityStaysQuarantinedUntilScopeChanges() {
        let tracker = SelectionAssociations()
        _ = tracker.observe(scope: "one", groups: [selection()])
        #expect(tracker.observe(scope: "one", groups: [selection(window: 999)]).status == .conflict)
        let missing = tracker.observe(scope: "one", groups: nil)
        #expect(missing.status == .unavailable)
        #expect(missing.quarantined)
        tracker.invalidate()
        #expect(tracker.observe(scope: "one", groups: [selection(12, window: 102, controls: [12])]).status == .conflict)
        #expect(tracker.observe(scope: "two", groups: [selection()]).bindings == [1: [11: 101]])
    }

    @Test func duplicatePhysicalWindowsAndSharedControlsAreRejected() {
        let tracker = SelectionAssociations()
        _ = tracker.observe(scope: "one", groups: [selection()])
        #expect(tracker.observe(scope: "one", groups: [selection(12)]).status == .conflict)
        let sharedControl = selection(11, window: 202, controls: [11, 22], group: 2)
        #expect(tracker.observe(scope: "two", groups: [selection(), sharedControl]).status == .conflict)
        let other = selection(21, window: 101, controls: [21, 22], group: 2)
        #expect(tracker.observe(scope: "three", groups: [selection(), other]).status == .conflict)
    }

    @Test func invalidMetadataCannotProduceAssociations() {
        for invalid in [selection(99), selection(window: 0), selection(controls: [11, 11]),
                        selection(controls: [11, -1]), selection(group: 11)] {
            #expect(SelectionAssociations().observe(scope: "one", groups: [invalid]).status == .conflict)
        }
        #expect(SelectionAssociations().observe(scope: "", groups: [selection()]).status == .unavailable)
    }

    @Test func contentConflictPreservesUnrelatedLearningAndRetainsQuarantine() {
        let tracker = SelectionAssociations()
        let other = selection(21, window: 201, controls: [21, 22], group: 2)
        _ = tracker.observe(scope: "one", groups: [selection(), other])
        let learned = tracker.observe(scope: "one", groups: [selection(12),
            selection(22, window: 202, controls: [21, 22], group: 2)])
        #expect(learned.status == .observed)
        #expect(!learned.scopeQuarantined)
        #expect(learned.quarantinedGroups == [1])
        #expect(learned.bindings == [2: [21: 201, 22: 202]])
        let blocked = learned.json["groups"] as! [[String: Any]]
        #expect(blocked[0]["quarantined"] as? Bool == true)
        #expect(blocked[0]["complete"] as? Bool == false)
        #expect(blocked[1]["complete"] as? Bool == true)
        #expect(tracker.observe(scope: "one", groups: nil).quarantinedGroups == [1])
        _ = tracker.observe(scope: "one", groups: [])
        tracker.invalidate()
        let returned = tracker.observe(scope: "one", groups: [selection(12, controls: [12]), other])
        #expect(returned.quarantinedGroups == [1])
        #expect(returned.bindings == [2: [21: 201]])
        #expect(tracker.observe(scope: "two", groups: [selection()]).quarantinedGroups.isEmpty)
    }

    @Test func crossGroupCollisionQuarantinesEveryClaimantButPreservesThirdGroup() {
        for reversed in [false, true] {
            let tracker = SelectionAssociations()
            let groups = [selection(), selection(21, controls: [21, 22], group: 2),
                          selection(31, window: 301, controls: [31, 32], group: 3)]
            let report = tracker.observe(scope: "one", groups: reversed ? groups.reversed() : groups)
            #expect(report.quarantinedGroups == [1, 2])
            #expect(!report.scopeQuarantined)
            #expect(report.bindings == [3: [31: 301]])
            let stillColliding = tracker.observe(scope: "one", groups: [selection(),
                selection(31, controls: [31, 32], group: 3)])
            #expect(stillColliding.quarantinedGroups == [1, 2, 3])
        }
    }

    @Test func sharedAXIdentitiesQuarantineTheWholeScope() {
        let report = SelectionAssociations().observe(scope: "one", groups: [selection(),
            selection(11, window: 201, controls: [11, 22], group: 2),
            selection(31, window: 301, controls: [31, 32], group: 3)])
        #expect(report.scopeQuarantined)
        #expect(report.bindings.isEmpty)
    }

    private func nodes() -> [[String: Any]] {
        let owner: [String: Any] = ["error": 0, "nodes": [0]]
        return [
            ["AXRole": "AXWindow", "windowID": UInt32(101)],
            ["AXRole": "AXTabGroup", "axIdentity": 1, "AXWindow": owner,
             "AXTabs": ["error": 0, "count": 2, "nodes": [2, 3]]],
            ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 11,
             "AXValue": true, "AXWindow": owner],
            ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 12,
             "AXValue": false, "AXWindow": owner]
        ]
    }

    @Test func graphAdapterRequiresAffirmativeSelectionAndRootOwnership() {
        #expect(TabSelectionEvidence.parse(nodes: nodes(), roots: [0], complete: true) == [selection()])
        var missing = nodes()
        missing[3].removeValue(forKey: "AXValue")
        #expect(TabSelectionEvidence.parse(nodes: missing, roots: [0], complete: true) ==
            [TabSelection(group: 1, controls: [11, 12], selected: nil, window: 101)])
        var foreign = nodes()
        foreign[3]["AXWindow"] = ["error": 0, "nodes": [3]]
        #expect(TabSelectionEvidence.parse(nodes: foreign, roots: [0], complete: true) == nil)
        #expect(TabSelectionEvidence.parse(nodes: nodes(), roots: [], complete: true) == nil)
        #expect(TabSelectionEvidence.parse(nodes: nodes(), roots: [0], complete: false) == nil)
    }

    @Test func graphIssuesIdentifySelectionReadFailuresWithoutChangingGroupIsolation() {
        var graph = nodes()
        graph[3].removeValue(forKey: "AXValue")
        graph[3]["AXValueError"] = AXError.noValue.rawValue
        let capture = TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true)
        #expect(capture.groups == [TabSelection(group: 1, controls: [11, 12], selected: nil, window: 101)])
        #expect(capture.issues == [.init(reason: .selectionValueUnavailable, node: 3, attribute: "AXValue",
                                       error: Int(AXError.noValue.rawValue))])
        #expect(capture.issues[0].json["error"] as? Int == Int(AXError.noValue.rawValue))
        graph[3]["AXValueError"] = 0
        #expect(TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true).issues[0].error == 0)
        graph[3]["AXValue"] = true
        #expect(TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true).issues ==
            [.init(reason: .selectionAmbiguous, node: 1, attribute: "AXTabs")])
        #expect(TabSelectionEvidence.inspect(nodes: nodes(), roots: [0], complete: true).issues.isEmpty)
    }

    @Test func graphIssuesDistinguishCaptureStructureAndOwnershipRejections() {
        #expect(TabSelectionEvidence.inspect(nodes: nodes(), roots: [0], complete: false).issues ==
            [.init(reason: .incompleteCapture)])
        #expect(TabSelectionEvidence.inspect(nodes: nodes(), roots: [], complete: true).issues ==
            [.init(reason: .noRoots)])
        #expect(TabSelectionEvidence.inspect(nodes: nodes(), roots: [99], complete: true).issues ==
            [.init(reason: .invalidRoot)])
        for (node, attribute, reason) in [
            (1, "axIdentity", TabSelectionEvidence.Issue.Reason.groupIdentityUnavailable),
            (1, "AXWindow", .groupOwnerUnavailable), (1, "AXTabs", .tabsUnavailable),
            (2, "AXRole", .nodeRoleUnavailable), (2, "AXSubrole", .controlMetadataUnavailable),
            (2, "axIdentity", .controlMetadataUnavailable), (2, "AXWindow", .controlMetadataUnavailable)
        ] {
            var graph = nodes()
            graph[node].removeValue(forKey: attribute)
            let capture = TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true)
            #expect(capture.groups == nil)
            #expect(capture.issues == [.init(reason: reason, node: node, attribute: attribute)])
        }
        var graph = nodes()
        graph[1]["AXTabs"] = ["error": AXError.cannotComplete.rawValue]
        #expect(TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true).issues ==
            [.init(reason: .tabsUnavailable, node: 1, attribute: "AXTabs", error: Int(AXError.cannotComplete.rawValue))])
    }

    @Test func unreadableRolesCannotBecomeAnObservedEmptyTabTopology() {
        for index in [0, 1, 2, 3] {
            var graph = nodes()
            graph[index].removeValue(forKey: "AXRole")
            graph[index]["AXRoleError"] = AXError.cannotComplete.rawValue
            let tracker = SelectionAssociations()
            _ = tracker.observe(scope: "one", groups: [selection()])
            let capture = TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true)
            #expect(capture.groups == nil)
            #expect(capture.issues == [.init(reason: .nodeRoleUnavailable, node: index, attribute: "AXRole",
                                           error: Int(AXError.cannotComplete.rawValue))])
            let report = tracker.observe(scope: "one", groups: capture.groups)
            #expect(report.status == .unavailable)
            #expect(report.bindings.isEmpty)
            #expect(report.resets == [.init(reason: .captureUnavailable, group: 1, discardedBindings: 1)])
            #expect(tracker.observe(scope: "one", groups: [selection(12, window: 102)]).bindings == [1: [12: 102]])
        }
    }

    @Test func rejectedRootWithholdsOtherwiseUsableLearningUntilFreshRecovery() {
        for reason in ["foreignOwner", "ownerUnavailable", "nonWindowRole", "roleUnavailable", "notRead"] {
            var graph = nodes()
            graph[0]["rootValidation"] = ["status": "accepted", "pidError": 0]
            graph.append(["AXRole": "AXApplication", "rootValidation": ["status": "unavailable", "reason": reason]])
            let tracker = SelectionAssociations()
            _ = tracker.observe(scope: "one", groups: [selection()])
            _ = tracker.observe(scope: "one", groups: [selection(12, window: 102)])
            let capture = TabSelectionEvidence.inspect(nodes: graph, roots: [0, 4, 4], complete: true)
            #expect(capture.groups == nil)
            #expect(capture.issues == [.init(reason: .rootReferenceUnavailable, node: 4)])
            let unavailable = tracker.observe(scope: "one", groups: capture.groups)
            #expect(unavailable.status == .unavailable)
            #expect(unavailable.bindings.isEmpty)
            #expect(unavailable.resets == [.init(reason: .captureUnavailable, group: 1, discardedBindings: 2)])
            graph.removeLast()
            let recovered = TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true)
            #expect(recovered.groups == [selection()])
            #expect(tracker.observe(scope: "one", groups: recovered.groups).bindings == [1: [11: 101]])
        }
    }

    @Test func missingRootValidationStatusCannotAffirmAcceptedOwnership() {
        var graph = nodes()
        graph[0]["rootValidation"] = ["pidError": 0]
        #expect(TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true).groups == nil)
        graph[0]["rootValidation"] = ["status": "accepted", "pidError": 0]
        #expect(TabSelectionEvidence.inspect(nodes: graph, roots: [0], complete: true).groups == [selection()])
    }

    @Test func graphAdapterRejectsDuplicateSelectionAndIncompleteTabs() {
        var multiple = nodes()
        multiple[3]["AXValue"] = true
        #expect(TabSelectionEvidence.parse(nodes: multiple, roots: [0], complete: true) ==
            [TabSelection(group: 1, controls: [11, 12], selected: nil, window: 101)])
        var partial = nodes()
        partial[1]["AXTabs"] = ["error": 0, "count": 3, "nodes": [2, 3]]
        #expect(TabSelectionEvidence.parse(nodes: partial, roots: [0], complete: true) == nil)
        #expect(TabSelectionEvidence.parse(nodes: nodes(), roots: [99], complete: true) == nil)
    }

    @Test func graphAdapterAcceptsNativeAXResultAndBooleanTypes() {
        var native = nodes()
        let owner: [String: Any] = ["error": AXError.success.rawValue, "nodes": [0]]
        for index in [1, 2, 3] { native[index]["AXWindow"] = owner }
        native[1]["AXTabs"] = ["error": AXError.success.rawValue, "count": 2, "nodes": [2, 3]]
        native[2]["AXValue"] = kCFBooleanTrue as CFBoolean
        native[3]["AXValue"] = kCFBooleanFalse as CFBoolean
        #expect(TabSelectionEvidence.parse(nodes: native, roots: [0], complete: true) == [selection()])
    }

    @Test func missingSelectionOnlyClearsItsKnownGroupAndNeverReplaysBindings() {
        let tracker = SelectionAssociations()
        let missing = TabSelection(group: 2, controls: [21, 22], selected: nil, window: 201)
        let other = selection(21, window: 201, controls: [21, 22], group: 2)
        _ = tracker.observe(scope: "one", groups: [selection(), other])
        let partial = tracker.observe(scope: "one", groups: [selection(12, window: 102), missing])
        #expect(partial.status == .observed)
        #expect(partial.bindings == [1: [11: 101, 12: 102]])
        #expect(partial.unavailableGroups == [2])
        #expect(!partial.quarantined)
        let json = partial.json["groups"] as! [[String: Any]]
        #expect(json[0]["complete"] as? Bool == true)
        #expect(json[1]["selectionKnown"] as? Bool == false)
        #expect(json[1]["complete"] as? Bool == false)
        let recovered = tracker.observe(scope: "one", groups: [selection(),
            selection(22, window: 202, controls: [21, 22], group: 2)])
        #expect(recovered.bindings[2] == [22: 202])
        #expect(recovered.bindings[1] == [11: 101, 12: 102])
        let unavailable = tracker.observe(scope: "one", groups: [missing])
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.unavailableGroups == [2])
        #expect(unavailable.bindings.isEmpty)
    }

    @Test func unavailableGroupStillReservesItsCurrentOwnerForCollisionChecks() {
        let tracker = SelectionAssociations()
        let unknown = TabSelection(group: 2, controls: [21, 22], selected: nil, window: 101)
        let report = tracker.observe(scope: "one", groups: [selection(), unknown,
            selection(31, window: 301, controls: [31, 32], group: 3)])
        #expect(report.quarantinedGroups == [1, 2])
        #expect(report.unavailableGroups == [2])
        #expect(report.bindings == [3: [31: 301]])
    }

    @Test func partialSelectionCannotHideSharedControlIdentities() {
        let unknown = TabSelection(group: 2, controls: [11, 22], selected: nil, window: 201)
        let report = SelectionAssociations().observe(scope: "one", groups: [selection(), unknown])
        #expect(report.scopeQuarantined)
        #expect(report.bindings.isEmpty)
    }

    @Test func graphSelectionIsolationStillRejectsUnknownOwnershipForWholeCapture() {
        var graph = nodes()
        graph[3].removeValue(forKey: "AXValue")
        let owner: [String: Any] = ["error": 0, "nodes": [4]]
        graph += [
            ["AXRole": "AXWindow", "windowID": UInt32(201)],
            ["AXRole": "AXTabGroup", "axIdentity": 2, "AXWindow": owner,
             "AXTabs": ["error": 0, "count": 2, "nodes": [6, 7]]],
            ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 21,
             "AXValue": true, "AXWindow": owner],
            ["AXRole": "AXRadioButton", "AXSubrole": "AXTabButton", "axIdentity": 22,
             "AXValue": false, "AXWindow": owner]
        ]
        let tracker = SelectionAssociations()
        let report = tracker.observe(scope: "one", groups: TabSelectionEvidence.parse(nodes: graph, roots: [0, 4], complete: true))
        #expect(report.status == .observed)
        #expect(report.unavailableGroups == [1])
        #expect(report.bindings == [2: [21: 201]])
        graph[3]["AXWindow"] = owner
        #expect(TabSelectionEvidence.parse(nodes: graph, roots: [0, 4], complete: true) == nil)
        let unknown = tracker.observe(scope: "one", groups: TabSelectionEvidence.parse(nodes: graph, roots: [0, 4], complete: true))
        #expect(unknown.status == .unavailable)
        #expect(unknown.groups.isEmpty && unknown.bindings.isEmpty)
    }

    @Test func radioSelectionNumbersAreExplicitlyBoundedAndRoleScoped() {
        #expect(TabSelectionValue.read(NSNumber(value: 1), role: "AXRadioButton", attribute: "AXValue")?.value == true)
        #expect(TabSelectionValue.read(NSNumber(value: 0), role: "AXRadioButton", attribute: "AXValue")?.value == false)
        #expect(TabSelectionValue.read(NSNumber(value: 1), role: "AXRadioButton", attribute: "AXValue")?.encoding == "number01")
        #expect(TabSelectionValue.read(NSNumber(value: 2), role: "AXRadioButton", attribute: "AXValue") == nil)
        #expect(TabSelectionValue.read(NSNumber(value: 1), role: "AXStaticText", attribute: "AXValue") == nil)
        #expect(TabSelectionValue.read(NSNumber(value: 1), role: "AXRadioButton", attribute: "AXSelected") == nil)
        #expect(TabSelectionValue.read("not captured" as CFString, role: "AXRadioButton", attribute: "AXValue") == nil)
        #expect(TabSelectionValue.read(kCFBooleanTrue, role: nil, attribute: "AXSelected")?.encoding == "boolean")
    }
}
