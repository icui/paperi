import AppKit
import Testing
@testable import PaperiPlatform

@MainActor struct EventRecorderLifecycleTests {
    @Test func repeatedStartAndStopDoNotDuplicateWorkspaceObservers() {
        let center = NotificationCenter()
        var records: [[String: Any]] = []
        var enumerations = 0
        let recorder = EventRecorder(workspaceCenter: center, runningApplications: {
            enumerations += 1
            return []
        }, emit: { records.append($0) })
        recorder.start()
        recorder.start()
        #expect(enumerations == 1)
        #expect(records.count == 1)
        #expect(records[0]["event"] as? String == "recorderReady")
        #expect(records[0]["observerCount"] as? Int == 0)

        // Termination delivery exercises workspace observation without AX calls.
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        #expect(records.count == 2)
        recorder.stop()
        recorder.stop()
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        #expect(records.count == 2)

        recorder.start()
        #expect(enumerations == 2)
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        #expect(records.count == 4)
        #expect(records[3]["event"] as? String == NSWorkspace.didTerminateApplicationNotification.rawValue)
        recorder.stop()
    }

    @Test func releasingRunningRecorderRemovesWorkspaceObservers() {
        let center = NotificationCenter()
        var records: [[String: Any]] = []
        var recorder: EventRecorder? = EventRecorder(workspaceCenter: center,
            runningApplications: { [] }, emit: { records.append($0) })
        weak var released = recorder
        recorder?.start()
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        #expect(records.count == 2)
        recorder = nil
        #expect(released == nil)
        released = nil
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        #expect(records.count == 2)
    }

    @Test func malformedWorkspaceEventsAreIgnored() {
        let center = NotificationCenter()
        var records: [[String: Any]] = []
        let recorder = EventRecorder(workspaceCenter: center,
            runningApplications: { [] }, emit: { records.append($0) })
        recorder.start()
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: "invalid"])
        #expect(records.count == 1)
        recorder.stop()
    }

    @Test func bundleFilterExcludesInitialAppsAndWorkspaceEvents() {
        let center = NotificationCenter()
        var records: [[String: Any]] = []
        let recorder = EventRecorder(workspaceCenter: center,
            runningApplications: { [NSRunningApplication.current] },
            bundleIDs: [], emit: { records.append($0) })
        recorder.start()
        post(NSWorkspace.didLaunchApplicationNotification, to: center)
        post(NSWorkspace.didTerminateApplicationNotification, to: center)
        #expect(records.count == 1)
        #expect(records[0]["observerCount"] as? Int == 0)
        recorder.stop()
    }

    @Test func queuedWorkspaceCallbackFromOldRunCannotAffectRestart() {
        let center = CapturedWorkspaceCenter()
        var records: [[String: Any]] = []
        let recorder = EventRecorder(workspaceCenter: center,
            runningApplications: { [] }, emit: { records.append($0) })
        recorder.start()
        let old = center.handlers.last!.callback
        recorder.stop()
        recorder.start()
        let current = center.handlers.last!.callback
        let notification = Notification(name: NSWorkspace.didTerminateApplicationNotification,
            userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        // A notification may already have been queued when its observer is removed.
        // Deliver a retained old callback after replacement, without real AX work.
        old(notification)
        #expect(records.count == 2)
        current(notification)
        #expect(records.count == 3)
        #expect(records.last?["event"] as? String == NSWorkspace.didTerminateApplicationNotification.rawValue)
        recorder.stop()
    }

    private func post(_ name: Notification.Name, to center: NotificationCenter) {
        center.post(name: name, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
    }
}

// Used only synchronously by the main-actor test. Retaining callbacks models
// delivery already queued before removeObserver, without scheduling global work.
private final class CapturedWorkspaceCenter: NotificationCenter, @unchecked Sendable {
    struct Handler { let callback: @Sendable (Notification) -> Void }
    var handlers: [Handler] = []

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        handlers.append(Handler(callback: block))
        return NSObject()
    }

    override func removeObserver(_ observer: Any) {}
}
