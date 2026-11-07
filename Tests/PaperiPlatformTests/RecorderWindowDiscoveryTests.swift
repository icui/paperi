import ApplicationServices
import Testing
@testable import PaperiPlatform

struct RecorderWindowDiscoveryTests {
    @Test func freshFocusAndMainReferencesRecoverEmptyEnumeration() {
        let focused = AXUIElementCreateApplication(12345)
        let main = AXUIElementCreateApplication(12346)
        let result = RecorderWindowDiscovery.collect(enumerated: [], focused: focused, main: main, pid: 42) { _ in
            (42, "AXWindow")
        }
        #expect(result.windows.count == 2)
        #expect(result.windows[0].sources == ["AXFocusedWindow"])
        #expect(result.windows[1].sources == ["AXMainWindow"])
        #expect(result.rejectedCount == 0)
    }

    @Test func equalReferencesDeduplicateAcrossDiscoverySources() {
        let first = AXUIElementCreateApplication(12345)
        let equal = AXUIElementCreateApplication(12345)
        var reads = 0
        let result = RecorderWindowDiscovery.collect(enumerated: [first, equal], focused: equal, main: first, pid: 42) { _ in
            reads += 1
            return (42, "AXWindow")
        }
        #expect(result.windows.count == 1)
        #expect(result.windows[0].sources == ["AXWindows", "AXFocusedWindow", "AXMainWindow"])
        #expect(reads == 1)
    }

    @Test func foreignUnknownAndNonWindowReferencesNeverBecomeSubscriptions() {
        let element = AXUIElementCreateApplication(12345)
        for facts: (pid: pid_t?, role: String?) in [(99, "AXWindow"), (nil, "AXWindow"), (42, nil), (42, "AXButton")] {
            let result = RecorderWindowDiscovery.collect(enumerated: [element], focused: nil, main: nil, pid: 42) { _ in facts }
            #expect(result.windows.isEmpty)
            #expect(result.rejectedCount == 1)
        }
        let sheet = RecorderWindowDiscovery.collect(enumerated: [], focused: element, main: nil, pid: 42) { _ in (42, "AXSheet") }
        #expect(sheet.windows.count == 1)
        let absent = RecorderWindowDiscovery.collect(enumerated: [], focused: nil, main: nil, pid: 42) { _ in
            Issue.record("No metadata read should occur without fresh references")
            return (42, "AXWindow")
        }
        #expect(absent.windows.isEmpty)
    }
}
