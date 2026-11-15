import ApplicationServices
import Testing
@testable import PaperiPlatform

struct EvidenceIdentitiesTests {
    @Test func equalityTokensSurviveSamplesWithinOneScope() {
        let identities = EvidenceIdentities()
        let first = AXUIElementCreateApplication(12345)
        let equivalent = AXUIElementCreateApplication(12345)
        let other = AXUIElementCreateApplication(12346)
        #expect(identities.token(for: first) == identities.token(for: equivalent))
        #expect(identities.token(for: first) != identities.token(for: other))
        let replacement = EvidenceIdentities()
        #expect(identities.scope != replacement.scope)
        #expect(!identities.exhausted)
    }

    @Test func capacityDoesNotRecycleOrInventIdentities() {
        let identities = EvidenceIdentities(capacity: 1)
        let first = AXUIElementCreateApplication(12345)
        #expect(identities.token(for: first) == 1)
        #expect(identities.token(for: AXUIElementCreateApplication(12346)) == nil)
        #expect(identities.exhausted)
        #expect(identities.token(for: AXUIElementCreateApplication(12345)) == 1)
        #expect(EvidenceIdentities(capacity: 0).token(for: first) == nil)
    }

    /// Short-lived windows (a print popup per print) fill the table; renewal
    /// restores tokens under a new scope instead of recycling old ones.
    @Test func renewalStartsAFreshScopeAfterExhaustion() {
        let identities = EvidenceIdentities(capacity: 2)
        let oldScope = identities.scope
        for pid in pid_t(12345)...12347 { _ = identities.token(for: AXUIElementCreateApplication(pid)) }
        #expect(identities.exhausted)
        identities.renew()
        #expect(!identities.exhausted)
        #expect(identities.scope != oldScope)
        #expect(identities.token(for: AXUIElementCreateApplication(12347)) == 1)
        #expect(identities.token(for: AXUIElementCreateApplication(12345)) == 2)
    }

    /// The renewed scope also lifts a quarantine learned under the old one.
    @Test func renewalResetsSelectionAssociationsKeyedByScope() {
        let identities = EvidenceIdentities(capacity: 1)
        let tracker = SelectionAssociations()
        let group = TabSelection(group: 1, controls: [1, 1], selected: 1, window: 101)
        #expect(tracker.observe(scope: identities.scope, groups: [group]).scopeQuarantined)
        identities.renew()
        let valid = TabSelection(group: 1, controls: [2, 3], selected: 2, window: 101)
        let report = tracker.observe(scope: identities.scope, groups: [valid])
        #expect(!report.scopeQuarantined)
        #expect(report.status == .observed)
    }
}
