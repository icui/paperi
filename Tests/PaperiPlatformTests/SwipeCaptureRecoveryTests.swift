import Testing
import PaperiCore
@testable import PaperiPlatform

@MainActor
struct SwipeCaptureRecoveryTests {
    private func manager() -> LiveManager {
        let manager = LiveManager(options: .init())
        manager.swipe = LiveManager.Swipe(
            space: 1, generation: manager.motionGeneration, overlay: SnapshotTransition(), surveys: [:],
            ends: [:], neighbours: [:], canvas: Rect(x: 0, y: 0, width: 1000, height: 800),
            closeWindow: nil, tabClose: nil)
        manager.swipeBegan = 10
        return manager
    }

    @Test func failedCaptureBeforeReleaseClearsMotion() {
        let manager = manager()
        manager.swipe?.captureState = .failed
        manager.endSwipe(commit: false)
        #expect(manager.swipe == nil)
        #expect(!manager.motionActive)
        #expect(!manager.gestureBlockedByAnimation)
    }

    @Test func failedCaptureAfterReleaseClearsMotion() {
        let manager = manager()
        manager.endSwipe(commit: false)
        #expect(manager.gestureBlockedByAnimation)
        // The capture completion replays the stored release after marking failure.
        manager.swipe?.captureState = .failed
        let released = manager.swipe!.released!
        manager.swipe?.released = nil
        manager.endSwipe(commit: released)
        #expect(manager.swipe == nil)
        #expect(!manager.gestureBlockedByAnimation)
    }

    @Test func stalledCaptureCancelsGenerationAndDeferredGesture() {
        let manager = manager()
        let generation = manager.motionGeneration
        manager.endSwipe(commit: false)
        manager.gestureDeferred = true
        #expect(!manager.expirePendingCapture(at: 11.99))
        #expect(manager.expirePendingCapture(at: 12))
        #expect(manager.motionGeneration != generation)
        #expect(manager.swipe == nil)
        #expect(!manager.gestureDeferred)
        #expect(!manager.motionActive)
        #expect(!manager.gestureBlockedByAnimation)
    }

    @Test func readyCaptureDoesNotExpireWhileFingersRemainDown() {
        let manager = manager()
        manager.swipe?.captureState = .ready
        #expect(!manager.expirePendingCapture(at: 100))
        #expect(manager.swipe != nil)
    }
}
