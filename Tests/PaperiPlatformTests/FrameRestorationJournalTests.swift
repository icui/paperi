import Testing
import PaperiCore
@testable import PaperiPlatform

struct FrameRestorationJournalTests {
    let original = Rect(x: 10, y: 20, width: 400, height: 300)
    let changed = Rect(x: 40, y: 80, width: 500, height: 350)

    @Test func firstAdmissionWinsAndClosedWindowsAreNotRestored() {
        var journal = FrameRestorationJournal()
        journal.remember(windowID: 1, frame: original)
        journal.remember(windowID: 1, frame: changed)
        journal.remember(windowID: 2, frame: original)
        journal.remove(windowID: 2)
        var writes: [UInt32: Rect] = [:]
        let results = journal.restore(managementStopped: true) { id, frame in writes[id] = frame; return true }
        #expect(writes == [1: original])
        #expect(results == [1: true])
    }

    @Test func restoreRequiresStopAndRunsOnlyOnceEvenOnFailure() {
        var journal = FrameRestorationJournal()
        journal.remember(windowID: 1, frame: original)
        var writes = 0
        #expect(journal.restore(managementStopped: false) { _, _ in writes += 1; return true } == nil)
        #expect(writes == 0)
        #expect(journal.restore(managementStopped: true) { _, _ in writes += 1; return false } == [1: false])
        #expect(journal.restore(managementStopped: true) { _, _ in writes += 1; return true } == nil)
        #expect(writes == 1)
        let admittedAfterStop = journal.remember(windowID: 2, frame: original)
        #expect(!admittedAfterStop)
    }
}
