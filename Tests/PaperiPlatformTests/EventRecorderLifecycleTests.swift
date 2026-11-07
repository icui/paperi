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

    private func post(_ name: Notification.Name, to center: NotificationCenter) {
        center.post(name: name, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
    }
}
