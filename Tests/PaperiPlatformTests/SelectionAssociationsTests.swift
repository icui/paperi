import ApplicationServices
import Testing
@testable import PaperiPlatform

struct SelectionAssociationsTests {
    private func selection(_ selected: Int = 11, window: UInt32 = 101,
                           controls: [Int] = [11, 12], group: Int = 1) -> TabSelection {
        TabSelection(group: group, controls: controls, selected: selected, window: window)
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
        _ = tracker.observe(scope: "one", groups: nil)
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
        #expect(TabSelectionEvidence.parse(nodes: missing, roots: [0], complete: true) == nil)
        var foreign = nodes()
        foreign[3]["AXWindow"] = ["error": 0, "nodes": [3]]
        #expect(TabSelectionEvidence.parse(nodes: foreign, roots: [0], complete: true) == nil)
        #expect(TabSelectionEvidence.parse(nodes: nodes(), roots: [], complete: true) == nil)
        #expect(TabSelectionEvidence.parse(nodes: nodes(), roots: [0], complete: false) == nil)
    }

    @Test func graphAdapterRejectsDuplicateSelectionAndIncompleteTabs() {
        var multiple = nodes()
        multiple[3]["AXValue"] = true
        #expect(TabSelectionEvidence.parse(nodes: multiple, roots: [0], complete: true) == nil)
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
}
