import ApplicationServices
import Testing
@testable import PaperiPlatform

struct TabRoleReadTests {
    @Test func transientFailureUsesOnlyFreshSuccessfulRole() {
        var reads = 0
        let result = TabRoleRead.collect(withinBudget: { true }) {
            reads += 1
            return reads == 1 ? (.cannotComplete, "AXApplication") : (.success, "AXWindow")
        }
        #expect(result.role == "AXWindow")
        #expect(result.errors == [.cannotComplete, .success])
        #expect(reads == 2)
    }

    @Test func persistentFailureIsBoundedAndNeverUsesReturnedValue() {
        var reads = 0
        let result = TabRoleRead.collect(withinBudget: { true }) {
            reads += 1
            return (.cannotComplete, "AXWindow")
        }
        #expect(result.role == nil)
        #expect(result.errors == [.cannotComplete, .cannotComplete])
        #expect(reads == 2)
    }

    @Test func exhaustedBudgetPreventsRetry() {
        var reads = 0
        let result = TabRoleRead.collect(withinBudget: { false }) {
            reads += 1
            return (.cannotComplete, nil)
        }
        #expect(result.role == nil)
        #expect(result.errors == [.cannotComplete])
        #expect(reads == 1)
    }

    @Test func otherErrorsAndMalformedSuccessAreNeverRetried() {
        for error in [AXError.success, .invalidUIElement, .attributeUnsupported] {
            for value: String? in [nil, "", "AXWindow"] {
                var reads = 0
                let result = TabRoleRead.collect(withinBudget: { true }) {
                    reads += 1
                    return (error, value)
                }
                #expect(reads == 1)
                #expect(result.errors == [error])
                #expect(result.role == (error == .success && value == "AXWindow" ? "AXWindow" : nil))
            }
        }
    }
}
