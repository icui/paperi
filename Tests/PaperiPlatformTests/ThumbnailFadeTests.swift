import Foundation
import Testing
@testable import PaperiPlatform

@MainActor struct ThumbnailFadeTests {
    @Test func newRevealCancelsFadeWithoutOverwritingRestoredOpacity() async throws {
        var opacity = 1.0
        let fade = Task { @MainActor in
            try await ThumbnailFade.run { value in
                opacity = value
                if value < 1 {
                    // A new reveal cancels the old task and restores visibility.
                    withUnsafeCurrentTask { $0?.cancel() }
                    opacity = 1
                }
            }
        }
        do {
            try await fade.value
            Issue.record("The superseded fade should be cancelled")
        } catch is CancellationError {
            #expect(opacity == 1)
        }
    }

    @Test func hoverDuringFadeRestoresFullVisibility() async throws {
        var hovered = false
        var restored = false
        var opacity = 1.0
        let fade = Task { @MainActor in
            try await ThumbnailFade.run(shouldStayVisible: { hovered }) { value in
                opacity = value
                if hovered {
                    restored = value == 1
                    withUnsafeCurrentTask { $0?.cancel() }
                } else if value < 1 {
                    hovered = true
                }
            }
        }
        do {
            try await fade.value
            Issue.record("The test should cancel after hover restores visibility")
        } catch is CancellationError {
            #expect(restored)
            #expect(opacity == 1)
        }
    }

    @Test func completedFadeReachesZero() async throws {
        var opacity = 1.0
        try await ThumbnailFade.run(duration: 0) { opacity = $0 }
        #expect(opacity == 0)
    }

    @Test func leaveDelayAppliesOnlyAfterFirstHold() async throws {
        // Never held: the initial delay keeps it fully visible.
        var opacity = 1.0
        let start = ProcessInfo.processInfo.systemUptime
        try await ThumbnailFade.run(duration: 0, delay: 0.15, leaveDelay: 0) { opacity = $0 }
        #expect(opacity == 0)
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.15)

        // Held once, then released: the shorter leave delay applies.
        var polls = 0
        let heldStart = ProcessInfo.processInfo.systemUptime
        try await ThumbnailFade.run(duration: 0, delay: 10, leaveDelay: 0,
                                    shouldStayVisible: { polls += 1; return polls == 1 }) { opacity = $0 }
        #expect(opacity == 0)
        #expect(ProcessInfo.processInfo.systemUptime - heldStart < 5)
    }
}
