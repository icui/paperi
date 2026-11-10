import CoreGraphics
import Testing
@testable import PaperiPlatform

struct DisplayArrangementTests {
    let builtIn = DisplayArrangement.Display(name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 932))

    @Test func sharedSpacesRequireEnablingSeparateSpaces() {
        #expect(DisplayArrangement.problem(displays: [builtIn], separateSpaces: false)?.contains("Displays have separate Spaces") == true)
        #expect(DisplayArrangement.problem(displays: [builtIn], separateSpaces: true) == nil)
        let above = DisplayArrangement.Display(name: "Above", frame: CGRect(x: 0, y: 932, width: 1280, height: 800))
        #expect(DisplayArrangement.problem(displays: [builtIn, above], separateSpaces: false) != nil)
        #expect(DisplayArrangement.problem(displays: [builtIn, above], separateSpaces: true) == nil)
    }

    @Test func stackedDisplaysAreFine() {
        let above = DisplayArrangement.Display(name: "InnoView", frame: CGRect(x: 107, y: 932, width: 1280, height: 800))
        let below = DisplayArrangement.Display(name: "TV", frame: CGRect(x: -300, y: -1080, width: 1920, height: 1080))
        #expect(DisplayArrangement.sideBySide([builtIn, above, below]).isEmpty)
        #expect(DisplayArrangement.sideBySide([builtIn]).isEmpty)
    }

    @Test func displaysBesideEachOtherAreReportedLeftToRight() {
        let left = DisplayArrangement.Display(name: "InnoView", frame: CGRect(x: -1280, y: 132, width: 1280, height: 800))
        let pairs = DisplayArrangement.sideBySide([builtIn, left])
        #expect(pairs.count == 1 && pairs[0].0.name == "InnoView" && pairs[0].1.name == "Built-in")
        // Diagonal neighbours that only touch at a corner are not side by side.
        let corner = DisplayArrangement.Display(name: "Corner", frame: CGRect(x: 1440, y: 932, width: 1280, height: 800))
        #expect(DisplayArrangement.sideBySide([builtIn, corner]).isEmpty)
    }
}
