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

    @Test func completedFadeReachesZero() async throws {
        var opacity = 1.0
        try await ThumbnailFade.run(duration: 0) { opacity = $0 }
        #expect(opacity == 0)
    }
}
