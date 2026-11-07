import Testing
@testable import PaperiPlatform

struct WindowCoverageTests {
    @Test func zeroReferencesNeverConfirmAnEmptyApplicationOrEmptyTabTopology() {
        let coverage = WindowCoverage(rootCount: 0, usableRootCount: 0, truncated: false)
        #expect(coverage.status == .noReferences)
        #expect(coverage.json["confirmsEmptyWindowSet"] as? Bool == false)
        let tracker = SelectionAssociations()
        _ = tracker.observe(scope: "one", groups: [TabSelection(group: 1, controls: [11, 12], selected: 11, window: 101)])
        let report = tracker.observe(scope: "one", groups: TabSelectionEvidence.parse(nodes: [], roots: [], complete: true))
        #expect(report.status == .unavailable)
        #expect(report.groups.isEmpty && report.bindings.isEmpty)
    }

    @Test func unusableOrTruncatedReferencesCannotAssertCoverage() {
        #expect(WindowCoverage(rootCount: 1, usableRootCount: 0, truncated: false).status == .unusableReferences)
        #expect(WindowCoverage(rootCount: 2, usableRootCount: 1, truncated: true).status == .truncated)
        #expect(WindowCoverage(rootCount: 0, usableRootCount: 0, truncated: true).status == .truncated)
        let partial = WindowCoverage(rootCount: 3, usableRootCount: 1, truncated: false)
        #expect(partial.status == .referencesAvailable)
        #expect(partial.usableRootCount == 1)
        #expect(partial.json["confirmsEmptyWindowSet"] as? Bool == false)
    }
}
