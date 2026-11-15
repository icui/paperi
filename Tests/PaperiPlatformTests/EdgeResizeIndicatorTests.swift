import Testing
import PaperiCore
@testable import PaperiPlatform

struct EdgeResizeIndicatorTests {
    let window = Rect(x: 100, y: 50, width: 600, height: 400)

    @Test func barSitsInsideTheMovingEdge() {
        // 5 thick, 96 long, 4 in from the edge, centred along it.
        #expect(EdgeResizeIndicator.bar(.right, of: window) == Rect(x: 691, y: 202, width: 5, height: 96))
        #expect(EdgeResizeIndicator.bar(.bottom, of: window) == Rect(x: 352, y: 441, width: 96, height: 5))
        #expect(EdgeResizeIndicator.bar(.top, of: window) == Rect(x: 352, y: 54, width: 96, height: 5))
    }

    @Test func barShortensOnSmallWindows() {
        let small = Rect(x: 0, y: 0, width: 300, height: 60)
        #expect(EdgeResizeIndicator.bar(.right, of: small).height == 44)
        #expect(EdgeResizeIndicator.bar(.right, of: Rect(x: 0, y: 0, width: 300, height: 10)).height == 16)
    }
}
