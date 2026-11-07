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
}
