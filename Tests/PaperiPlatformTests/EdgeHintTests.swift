import PaperiCore
import Testing
@testable import PaperiPlatform

struct EdgeHintTests {
    @Test func barSitsInsideTheEdgeThatWasPressed() {
        let frame = Rect(x: 100, y: 40, width: 1000, height: 800)
        #expect(EdgeHint.bar(along: frame, side: .left) == Rect(x: 106, y: 200, width: 5, height: 480))
        #expect(EdgeHint.bar(along: frame, side: .right) == Rect(x: 1089, y: 200, width: 5, height: 480))
        #expect(EdgeHint.bar(along: frame, side: .up) == Rect(x: 300, y: 46, width: 600, height: 5))
        #expect(EdgeHint.bar(along: frame, side: .down) == Rect(x: 300, y: 829, width: 600, height: 5))
    }
}
