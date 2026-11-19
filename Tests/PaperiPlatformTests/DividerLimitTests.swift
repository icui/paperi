import Testing
@testable import PaperiPlatform

struct DividerLimitTests {
    @Test func rowRoundingIsNotALimit() {
        // Terminal asked for 422 took 427; a 4-point shrink rounds back to 427.
        #expect(LiveManager.dividerLimit(wanted: 418, before: 427, actual: 427) == nil)
        // Growing by less than a row also rounds back.
        #expect(LiveManager.dividerLimit(wanted: 431, before: 427, actual: 427) == nil)
        // Rounding past the request (up a row) is not a refusal either.
        #expect(LiveManager.dividerLimit(wanted: 433, before: 427, actual: 442) == nil)
    }

    @Test func refusalsBeyondAStepAreLimits() {
        // Finder at its minimum height ignores a shrink well past a step.
        #expect(LiveManager.dividerLimit(wanted: 150, before: 200, actual: 200) == .minimum)
        #expect(LiveManager.dividerLimit(wanted: 900, before: 700, actual: 700) == .maximum)
        // It moved toward the request: not refused.
        #expect(LiveManager.dividerLimit(wanted: 150, before: 200, actual: 180) == nil)
    }

    @Test func steppedWritesLead() {
        // Terminal asked for 418 from 427 dropped a 14-point row to 413.
        #expect(LiveManager.steppedWrite(wanted: 418, before: 427, actual: 413))
        // A normal window lands on the request, give or take integral rounding.
        #expect(!LiveManager.steppedWrite(wanted: 421.6, before: 430, actual: 422))
        // Rounded back to the same row: no evidence yet.
        #expect(!LiveManager.steppedWrite(wanted: 423, before: 427, actual: 427))
        // Clamped part of the way (a minimum between): its edge leads too.
        #expect(LiveManager.steppedWrite(wanted: 150, before: 210, actual: 200))
    }
}
