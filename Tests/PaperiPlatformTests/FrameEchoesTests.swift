import Testing
import PaperiCore
@testable import PaperiPlatform

struct FrameEchoesTests {
    let a = Rect(x: 10, y: 20, width: 400, height: 300)
    let b = Rect(x: 10, y: 20, width: 480, height: 300)

    @Test func matchingEchoesRetainGenerationOnlyUntilDeadline() {
        var echoes = FrameEchoes()
        let generation = echoes.expect(windowID: 1, frame: a, now: 10)!
        #expect(echoes.observe(windowID: 1, frame: a, now: 10.2) == .expected(generation))
        #expect(echoes.observe(windowID: 1, frame: a, now: 11) == .expected(generation))
        #expect(echoes.observe(windowID: 1, frame: a, now: 12) == .external)
    }
    @Test func realResizeDuringPendingWriteIsNeverSuppressed() {
        var echoes = FrameEchoes()
        echoes.expect(windowID: 1, frame: a, now: 10)
        #expect(echoes.observe(windowID: 1, frame: b, now: 10.1) == .external)
        #expect(echoes.observe(windowID: 1, frame: a, now: 10.2) == .external)
    }
    @Test func replacementAndRemovalCannotMatchAnOldFrame() {
        var echoes = FrameEchoes()
        let old = echoes.expect(windowID: 1, frame: a, now: 10)
        let new = echoes.expect(windowID: 1, frame: b, now: 10.1)
        #expect(old != new)
        #expect(echoes.observe(windowID: 1, frame: a, now: 10.2) == .external)
        echoes.expect(windowID: 1, frame: b, now: 11)
        echoes.remove(windowID: 1)
        #expect(echoes.observe(windowID: 1, frame: b, now: 11.1) == .external)
        #expect(echoes.observe(windowID: 2, frame: b, now: 11.1) == .external)
    }
}
