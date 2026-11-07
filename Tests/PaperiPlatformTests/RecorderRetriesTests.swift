import Foundation
import Testing
@testable import PaperiPlatform

@MainActor struct RecorderRetriesTests {
    // Deliberately ignores cancellation until resumed, exercising the guard
    // against late completion without wall-clock sleeps or live processes.
    @MainActor private final class Clock {
        var sleepers: [CheckedContinuation<Void, Error>] = []
        var durations: [Duration] = []
        var reader: CheckedContinuation<Duration, Never>?

        func sleep(_ duration: Duration) async throws {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append(continuation)
                if let reader {
                    self.reader = nil
                    reader.resume(returning: duration)
                } else {
                    durations.append(duration)
                }
            }
        }
        func nextSleep() async -> Duration {
            if !durations.isEmpty { return durations.removeFirst() }
            return await withCheckedContinuation { reader = $0 }
        }
        func advance() { sleepers.removeFirst().resume() }
    }

    @Test func runsExactlyThreePassesAndReleasesCompletedEntry() async throws {
        let clock = Clock()
        let retries = RecorderRetries(sleep: { try await clock.sleep($0) })
        var attempts = 0
        let task = try #require(retries.schedule(1) { attempts += 1; return true })
        #expect(retries.schedule(1) { Issue.record("Duplicate schedule ran"); return true } == nil)
        for seconds in [1, 2, 4] {
            #expect(await clock.nextSleep() == .seconds(seconds))
            clock.advance()
        }
        await task.value
        #expect(attempts == 3)
        #expect(retries.pendingCount == 0)
    }

    @Test func earlyExitAndSleepErrorReleaseEntries() async throws {
        let clock = Clock()
        let retries = RecorderRetries(sleep: { try await clock.sleep($0) })
        var attempts = 0
        let task = try #require(retries.schedule(1) { attempts += 1; return false })
        _ = await clock.nextSleep()
        clock.advance()
        await task.value
        #expect(attempts == 1)
        #expect(retries.pendingCount == 0)

        let failed = RecorderRetries(sleep: { _ in throw CancellationError() })
        let failingTask = try #require(failed.schedule(1) { Issue.record("Failed sleep ran work"); return true })
        await failingTask.value
        #expect(failed.pendingCount == 0)
    }

    @Test func cancelledTaskCannotRunOrRemoveReplacement() async throws {
        let clock = Clock()
        let retries = RecorderRetries(sleep: { try await clock.sleep($0) })
        let old = try #require(retries.schedule(1) { Issue.record("Cancelled work ran"); return true })
        _ = await clock.nextSleep()
        retries.cancel(1)
        let replacement = try #require(retries.schedule(1) { return false })
        _ = await clock.nextSleep()
        clock.advance()
        await old.value
        #expect(retries.pendingCount == 1)
        clock.advance()
        await replacement.value
        #expect(retries.pendingCount == 0)
    }

    @Test func stopAndReleaseCancelPendingWork() async throws {
        let clock = Clock()
        var retries: RecorderRetries? = RecorderRetries(sleep: { try await clock.sleep($0) })
        let stopped = try #require(retries?.schedule(1) { Issue.record("Stopped work ran"); return true })
        _ = await clock.nextSleep()
        retries?.cancelAll()
        #expect(retries?.pendingCount == 0)
        clock.advance()
        await stopped.value
        let released = try #require(retries?.schedule(2) { Issue.record("Released work ran"); return true })
        _ = await clock.nextSleep()
        retries = nil
        #expect(released.isCancelled)
        clock.advance()
        await released.value
    }
}
