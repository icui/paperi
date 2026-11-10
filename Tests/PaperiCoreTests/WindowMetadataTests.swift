import Foundation
import Testing
@testable import PaperiCore

struct WindowMetadataTests {
    @Test func unknownPresentationStateCannotBecomeEligible() {
        var facts = WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow",
                                isRoot: true, movable: true, resizable: true, level: 0)
        #expect(WindowPolicy.classify(facts).eligibility == .tiled)
        facts.fullscreen = nil
        #expect(WindowPolicy.classify(facts).eligibility == .pending)
        #expect(WindowPolicy.classify(facts, userFloating: true).eligibility == .pending)
        facts.fullscreen = false
        facts.minimized = nil
        #expect(WindowPolicy.classify(facts).eligibility == .pending)
        facts.fullscreen = true
        #expect(WindowPolicy.classify(facts).eligibility == .excluded)
        facts.fullscreen = nil
        facts.subrole = "AXDialog"
        #expect(WindowPolicy.classify(facts).eligibility == .excluded)
    }

    @Test func decodedMissingPresentationStateRemainsUnknown() throws {
        let json = Data(#"{"bundleID":"test","role":"AXWindow","subrole":"AXStandardWindow","isRoot":true,"movable":true,"resizable":true,"level":0}"#.utf8)
        let facts = try JSONDecoder().decode(WindowFacts.self, from: json)
        #expect(facts.fullscreen == nil && facts.minimized == nil)
        #expect(WindowPolicy.classify(facts).eligibility == .pending)
        let restored = try JSONDecoder().decode(WindowFacts.self, from: JSONEncoder().encode(facts))
        #expect(restored == facts)
    }
}

struct UtilityWindowHeuristicTests {
    let base = WindowFacts(bundleID: "com.apple.finder", role: "AXWindow", subrole: "AXStandardWindow",
                           isRoot: true, movable: true, resizable: true, level: 0)
    @Test func windowsWithoutFullScreenButtonFloatUnlessForced() {
        var facts = base
        #expect(WindowPolicy.classify(facts).eligibility == .tiled)          // unknown: no heuristic
        facts.hasFullScreenButton = true
        #expect(WindowPolicy.classify(facts).eligibility == .tiled)
        facts.hasFullScreenButton = false
        #expect(WindowPolicy.classify(facts).eligibility == .floating)
        #expect(WindowPolicy.classify(facts, forceTile: true).eligibility == .tiled)
        facts.subrole = "AXDialog"
        #expect(WindowPolicy.classify(facts, forceTile: true).eligibility == .excluded)
    }
}
