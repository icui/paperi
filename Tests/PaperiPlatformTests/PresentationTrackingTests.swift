import Testing
@testable import PaperiPlatform

struct PresentationTrackingTests {
    @Test func backoffDoublesToCapAndResetsOnAnswer() {
        var r = AppResponsiveness()
        #expect(r.timedOut(7, now: 0) == 0.25)
        #expect(!r.available(7, now: 0.2))
        #expect(r.available(7, now: 0.25))
        #expect(r.timedOut(7, now: 1) == 0.5)
        #expect(r.timedOut(7, now: 2) == 1)
        for _ in 0..<6 { r.timedOut(7, now: 3) }
        #expect(r.timedOut(7, now: 10) == 5)
        r.answered(7)
        #expect(r.available(7, now: 10))
        #expect(r.timedOut(7, now: 10) == 0.25)
    }

    @Test func notificationShortensOnlyEarlyBackoffs() {
        var r = AppResponsiveness()
        r.timedOut(1, now: 0); r.timedOut(1, now: 0)
        r.heard(1, now: 0.1)
        #expect(r.available(1, now: 0.1))
        for _ in 0..<AppResponsiveness.eventRetries { r.timedOut(1, now: 1) }
        r.heard(1, now: 1.1)
        #expect(!r.available(1, now: 1.1), "a hung app that still posts keeps its backoff")
        r.heard(2, now: 0)
        #expect(r.available(2, now: 0))
    }

    @Test func requestedMinimizeHoldsSpaceUntilConfirmedOrExpired() {
        var t = MinimizeTracker()
        t.requested(10, space: 5, now: 0)
        #expect(t.pendingSpaces(now: 1) == [5])
        #expect(t.notified.isEmpty)
        t.observe(10, minimized: false)
        #expect(t.contains(10), "the effect may not have started")
        t.observe(10, minimized: nil)
        #expect(t.contains(10))
        t.minimizeNotified(10)
        #expect(t.pendingSpaces(now: 1).isEmpty)
        #expect(t.notified == [10])

        t.requested(11, space: 6, now: 0)
        #expect(t.pendingSpaces(now: MinimizeTracker.requestTimeout).isEmpty)
        t.expire(now: MinimizeTracker.requestTimeout)
        #expect(!t.contains(11))
        #expect(t.contains(10), "expiry applies only to requests")
    }

    @Test func surveyReadingsResolveNotifiedMinimize() {
        var t = MinimizeTracker()
        t.minimizeNotified(1); t.observe(1, minimized: true)
        #expect(!t.contains(1), "confirmed: ordinary observation owns it")
        t.minimizeNotified(2); t.observe(2, minimized: false)
        #expect(!t.contains(2), "restored without a restore notification")
        t.minimizeNotified(3); t.requested(3, space: 1, now: 0)
        #expect(t.notified == [3], "a request never downgrades a notification")
        t.restoreNotified(3)
        #expect(!t.contains(3))
    }
}

struct MinimizeTrackerPendingTests {
    @Test func pendingWindowsTrackOnlyUnconfirmedRequests() {
        var t = MinimizeTracker()
        t.requested(1, space: 9, now: 0)
        t.minimizeNotified(2)
        #expect(t.pendingWindows(now: 0.5) == [1])
        #expect(t.pendingWindows(now: MinimizeTracker.requestTimeout).isEmpty)
    }
}
