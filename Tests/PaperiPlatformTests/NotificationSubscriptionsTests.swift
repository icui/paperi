import ApplicationServices
import Testing
@testable import PaperiPlatform

struct NotificationSubscriptionsTests {
    @Test func successfulRequestsAreNotRepeatedForEqualReferences() {
        var subscriptions = NotificationSubscriptions()
        let element = AXUIElementCreateApplication(12345)
        let equivalent = AXUIElementCreateApplication(12345)
        #expect(CFEqual(element, equivalent))
        var attempts = 0
        let first = subscriptions.register(element, name: "AXWindowCreated") {
            attempts += 1
            return .success
        }
        let repeated = subscriptions.register(equivalent, name: "AXWindowCreated") {
            attempts += 1
            return .success
        }
        #expect(first == .success)
        #expect(repeated == nil)
        #expect(attempts == 1)
    }

    @Test func failuresRemainRetryableUntilConfirmedRegistered() {
        var subscriptions = NotificationSubscriptions()
        let element = AXUIElementCreateApplication(12345)
        for error: AXError in [.cannotComplete, .notificationUnsupported] {
            #expect(subscriptions.register(element, name: "AXMoved", perform: { error }) == error)
        }
        #expect(subscriptions.register(element, name: "AXMoved", perform: {
            .notificationAlreadyRegistered
        }) == .notificationAlreadyRegistered)
        #expect(subscriptions.register(element, name: "AXMoved", perform: {
            Issue.record("Confirmed registration must not be repeated")
            return .failure
        }) == nil)
    }

    @Test func coverageIsScopedToElementNotificationAndObserverLifetime() {
        var subscriptions = NotificationSubscriptions()
        let first = AXUIElementCreateApplication(12345)
        let second = AXUIElementCreateApplication(12346)
        #expect(subscriptions.register(first, name: "AXMoved", perform: { .success }) == .success)
        #expect(subscriptions.register(first, name: "AXResized", perform: { .success }) == .success)
        #expect(subscriptions.register(second, name: "AXMoved", perform: { .success }) == .success)
        subscriptions.remove(AXUIElementCreateApplication(12345))
        #expect(subscriptions.register(first, name: "AXMoved", perform: { .success }) == .success)
        #expect(subscriptions.register(second, name: "AXMoved", perform: { .failure }) == nil)
        // A replacement observer must register everything again.
        var replacement = NotificationSubscriptions()
        #expect(replacement.register(second, name: "AXMoved", perform: { .success }) == .success)
    }
}
