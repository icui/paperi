import ApplicationServices
import Foundation
import Testing
@testable import PaperiPlatform

/// Structural tab rules: shapes captured from Microsoft Word (ribbon `AXTabGroup`
/// directly under the window, tabs without `AXTabButton`) and Zoom (a direct
/// window child whose role reads back empty). Strict mode keeps the original
/// withholding behavior and is what `strictTabDetection` selects.
struct ContentTabRulesTests {
    static let unsupported = AXError.attributeUnsupported.rawValue
    static var owner: [String: Any] { ["error": Int32(0), "nodes": [0]] }

    static func window(_ id: UInt32, children: [Int]) -> [String: Any] {
        ["AXRole": "AXWindow", "AXRoleError": Int32(0), "windowID": id, "rootValidation": ["status": "accepted"],
         "AXChildren": ["error": Int32(0), "count": children.count, "nodes": children]]
    }

    static func tab(_ identity: Int, selected: Bool, subrole: String? = nil,
                    subroleError: Int32 = unsupported) -> [String: Any] {
        var node: [String: Any] = ["AXRole": "AXRadioButton", "AXRoleError": Int32(0), "axIdentity": identity,
                                   "AXValue": selected, "AXWindow": owner]
        if let subrole { node["AXSubrole"] = subrole; node["AXSubroleError"] = Int32(0) }
        else { node["AXSubroleError"] = subroleError }
        return node
    }

    /// Word: split group, ribbon tab group (Home/Insert), close button.
    static func wordNodes() -> [[String: Any]] {
        [window(77889, children: [1, 2, 5]),
         ["AXRole": "AXSplitGroup", "AXRoleError": Int32(0)],
         ["AXRole": "AXTabGroup", "AXRoleError": Int32(0), "axIdentity": 1, "AXWindow": owner,
          "AXTabs": ["error": Int32(0), "count": 2, "nodes": [3, 4]]],
         tab(11, selected: true), tab(12, selected: false),
         ["AXRole": "AXButton", "AXRoleError": Int32(0), "AXSubrole": "AXCloseButton"]]
    }

    /// Zoom: an empty-role child next to ordinary buttons.
    static func zoomNodes() -> [[String: Any]] {
        [window(145, children: [1, 2]),
         ["AXRoleError": Int32(0), "AXSubroleError": unsupported],
         ["AXRole": "AXButton", "AXRoleError": Int32(0)]]
    }

    static func report(_ nodes: [[String: Any]], strict: Bool?) -> [String: Any] {
        let tracker = SelectionAssociations()
        let capture = TabSelectionEvidence.inspect(nodes: nodes, roots: [0], complete: true, strict: strict ?? true)
        var app: [String: Any] = ["windowsError": Int32(0), "truncated": false, "identityTruncated": false,
                                  "identityScope": "test", "nodes": nodes, "roots": [0], "observedRoots": [Int](),
                                  "selectionAssociations": tracker.observe(scope: "test", groups: capture.groups).json]
        if let strict { app["strictTabEvidence"] = strict }
        return app
    }

    @Test func ribbonTabGroupIsContentUnderStructuralRulesOnly() {
        #expect(NativeTabMembership.inspectSingletons(Self.report(Self.wordNodes(), strict: false)) == [77889])
        #expect(NativeTabMembership.inspectSingletons(Self.report(Self.wordNodes(), strict: true)).isEmpty)
        // Reports without the key (older callers, probes) stay strict.
        #expect(NativeTabMembership.inspectSingletons(Self.report(Self.wordNodes(), strict: nil)).isEmpty)
        let capture = TabSelectionEvidence.inspect(nodes: Self.wordNodes(), roots: [0], complete: true, strict: false)
        #expect(capture.groups == [])
        #expect(capture.issues.isEmpty)
    }

    @Test func uncertainOrNativeLookingTabsStillWithhold() {
        var cases: [[[String: Any]]] = []
        // A tab whose subrole read timed out could be an AXTabButton.
        var nodes = Self.wordNodes(); nodes[4] = Self.tab(12, selected: false, subroleError: AXError.cannotComplete.rawValue)
        cases.append(nodes)
        // Mixed: one tab is a native tab button.
        nodes = Self.wordNodes(); nodes[4] = Self.tab(12, selected: false, subrole: "AXTabButton")
        cases.append(nodes)
        // Unreadable or partial tab list.
        nodes = Self.wordNodes(); nodes[2]["AXTabs"] = ["error": AXError.cannotComplete.rawValue]
        cases.append(nodes)
        nodes = Self.wordNodes(); nodes[2]["AXTabs"] = ["error": Int32(0), "count": 3, "nodes": [3, 4]]
        cases.append(nodes)
        // A tab with an unreadable role.
        nodes = Self.wordNodes(); nodes[3].removeValue(forKey: "AXRole"); nodes[3]["AXRoleError"] = AXError.cannotComplete.rawValue
        cases.append(nodes)
        for nodes in cases {
            #expect(NativeTabMembership.inspectSingletons(Self.report(nodes, strict: false)).isEmpty)
        }
    }

    @Test func nativeTabBarBesideRibbonIsStillDetected() {
        var nodes = Self.wordNodes()
        nodes[0] = Self.window(77889, children: [1, 2, 5, 6])
        nodes.append(["AXRole": "AXTabGroup", "AXRoleError": Int32(0), "axIdentity": 2, "AXWindow": Self.owner,
                      "AXTabs": ["error": Int32(0), "count": 2, "nodes": [7, 8]]])
        nodes.append(Self.tab(21, selected: true, subrole: "AXTabButton"))
        nodes.append(Self.tab(22, selected: false, subrole: "AXTabButton"))
        let capture = TabSelectionEvidence.inspect(nodes: nodes, roots: [0], complete: true, strict: false)
        #expect(capture.groups == [TabSelection(group: 2, controls: [21, 22], selected: 21, window: 77889)])
        #expect(NativeTabMembership.inspectSingletons(Self.report(nodes, strict: false)).isEmpty)
    }

    @Test func emptyButReadableRoleNoLongerWithholdsUnderStructuralRules() {
        #expect(NativeTabMembership.inspectSingletons(Self.report(Self.zoomNodes(), strict: false)) == [145])
        #expect(NativeTabMembership.inspectSingletons(Self.report(Self.zoomNodes(), strict: true)).isEmpty)
        // A failed role read may still hide a tab bar.
        var nodes = Self.zoomNodes(); nodes[1]["AXRoleError"] = AXError.cannotComplete.rawValue
        #expect(NativeTabMembership.inspectSingletons(Self.report(nodes, strict: false)).isEmpty)
        nodes = Self.zoomNodes(); nodes[1].removeValue(forKey: "AXRoleError")
        #expect(NativeTabMembership.inspectSingletons(Self.report(nodes, strict: false)).isEmpty)
    }

    @Test func topologyKeepsAManagedRibbonWindowAsItsOwnSlot() {
        #expect(NativeTabTopology.inspect(Self.report(Self.wordNodes(), strict: false), managed: [77889], destroyed: [])
            == [NativeTabPartition(members: [77889], active: 77889)])
        #expect(NativeTabTopology.inspect(Self.report(Self.wordNodes(), strict: true), managed: [77889], destroyed: []) == nil)
        #expect(NativeTabTopology.inspect(Self.report(Self.zoomNodes(), strict: false), managed: [145], destroyed: [])
            == [NativeTabPartition(members: [145], active: 145)])
    }

    @Test func strictTabDetectionConfigSelectsAppsOrEverything() throws {
        let none = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(none.strictTabDetection.isEmpty)
        #expect(!none.usesStrictTabDetection(bundleID: "com.microsoft.Word"))
        let some = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"strictTabDetection":["us.zoom.xos"]}"#.utf8))
        #expect(some.usesStrictTabDetection(bundleID: "us.zoom.xos"))
        #expect(!some.usesStrictTabDetection(bundleID: "com.microsoft.Word"))
        let all = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"strictTabDetection":["*"]}"#.utf8))
        #expect(all.usesStrictTabDetection(bundleID: "com.microsoft.Word"))
        #expect(all.usesStrictTabDetection(bundleID: nil))
        let roundTrip = try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(some))
        #expect(roundTrip.strictTabDetection == ["us.zoom.xos"])
        #expect(try JSONDecoder().decode(LiveConfig.self, from: Data(LiveConfig.template.utf8)).strictTabDetection.isEmpty)
    }
}
