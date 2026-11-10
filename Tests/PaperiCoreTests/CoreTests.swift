import Testing
@testable import PaperiCore

struct CoreTests {
    @Test func testResizeClampsWidthAndRedistributesHeight() throws {
        let canvas = Rect(x: -1000, y: 20, width: 1000, height: 800)
        var layout = Layout(columns: [Column(slots: [slot(1), slot(2), slot(3)], width: 400)], focused: "2")
        let before = try layout.placements(in: canvas)
        try layout.resizeWidth(by: 0.1, in: canvas)
        try layout.resizeHeight(by: 0.1, in: canvas)
        let after = try layout.placements(in: canvas)
        checkEqual(after[1].frame.width, 500)
        checkEqual(after[1].frame.height - before[1].frame.height, 80, accuracy: 0.00001)
        checkEqual(after[0].frame.height, after[2].frame.height, accuracy: 0.00001)
        checkEqual(after.last!.frame.y + after.last!.frame.height, 820, accuracy: 0.00001)
        try layout.resizeHeight(by: 100, in: canvas)
        try layout.resizeWidth(by: -100, in: canvas)
        checkTrue(try layout.placements(in: canvas).allSatisfy { $0.frame.isValid })
        checkEqual(layout.columns[0].width, 1)
    }
    @Test func testSplitHasEqualHalvesAndOneGap() throws {
        let canvas = Rect(x: -1000, y: 20, width: 1000, height: 800)
        var layout = Layout(columns: (1...3).map { Column(slots: [slot(UInt32($0))], width: 300) }, focused: "3")
        try layout.split(in: canvas)
        let frames = try layout.placements(in: canvas)
        // Column 1 remains to the left, so the pair keeps one margin there.
        checkEqual(frames[1].frame, Rect(x: -992, y: 20, width: 492, height: 800))
        checkEqual(frames[2].frame, Rect(x: -492, y: 20, width: 492, height: 800))
        var revealed = layout
        checkTrue(try !revealed.reveal(in: canvas))
        layout.focused = "1"
        let before = layout
        try layout.split(in: canvas)
        checkEqual(layout, before)
    }
    @Test func testFloatingPreservesTabsAndRejectsExcludedWindows() throws {
        let tabs = Slot(id: "tabs", members: [1, 2], activeMember: 2)
        var state = LayoutState(tiled: Layout(columns: [Column(slots: [tabs], width: 400)], focused: "tabs"))
        checkTrue(try state.toggleFloating(slotID: "tabs", classification: Classification(eligibility: .tiled, reason: "document")))
        try state.validate()
        checkTrue(state.tiled.columns.isEmpty)
        checkEqual(state.floating[0].slots[0], tabs)
        let before = state
        checkEqual(try state.toggleFloating(slotID: "tabs", classification: Classification(eligibility: .excluded, reason: "overlay")), false)
        checkEqual(state, before)
        checkTrue(try state.toggleFloating(slotID: "tabs", classification: Classification(eligibility: .floating, reason: "user floating")))
        try state.validate()
        checkEqual(state.tiled.focused, "tabs")
        checkEqual(state.tiled.columns[0].slots[0], tabs)
    }
    @Test func testInvalidResizeDoesNotMutate() throws {
        var layout = Layout(columns: [Column(slots: [slot(1)], width: 400)], focused: "1")
        let before = layout
        #expect(throws: (any Error).self) { try layout.resizeWidth(by: .nan, in: Rect(x: 0, y: 0, width: 1000, height: 800)) }
        checkEqual(layout, before)
    }
    func slot(_ id: UInt32) -> Slot { Slot(id: "\(id)", members: [id], activeMember: id) }
    @Test func testControlCenterNeverFloatsOrTiles() {
        let facts = WindowFacts(bundleID: "com.apple.controlcenter", role: "AXWindow", subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true)
        checkEqual(WindowPolicy.classify(facts, userFloating: true).eligibility, .excluded)
    }
    @Test func testUnknownMetadataStaysPendingAndSheetExcluded() {
        checkEqual(WindowPolicy.classify(WindowFacts(bundleID: "test")).eligibility, .pending)
        checkEqual(WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXSheet", subrole: "AXDialog")).eligibility, .excluded)
    }
    @Test func testMissingLevelIsPendingAndDocumentCanTile() {
        var facts = WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true)
        checkEqual(WindowPolicy.classify(facts).eligibility, .pending)
        facts.level = 0
        checkEqual(WindowPolicy.classify(facts).eligibility, .tiled)
        facts.level = 8
        checkEqual(WindowPolicy.classify(facts).eligibility, .excluded)
    }
    @Test func testNeighborFallsBackToExistingRowAndDoesNotWrap() {
        let layout = Layout(columns: [Column(slots: [slot(1), slot(2)], width: 400), Column(slots: [slot(3)], width: 400)], focused: "2")
        checkEqual(layout.neighbor(.right), "3")
        checkNil(layout.neighbor(.left))
    }
    @Test func testSlurpBarfMaintainMembership() throws {
        var layout = Layout(columns: [Column(slots: [slot(1)], width: 400), Column(slots: [slot(2)], width: 400)], focused: "2")
        layout.slurp(); try layout.validate()
        checkEqual(layout.columns.count, 1)
        layout.barf(); try layout.validate()
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["1"], ["2"]])
    }
    @Test func testHorizontalSwapMovesWholeColumn() {
        var layout = Layout(columns: [Column(slots: [slot(1), slot(2)], width: 400), Column(slots: [slot(3)], width: 500)], focused: "2")
        layout.swap(.right)
        checkEqual(layout.columns[1].slots.map(\.id), ["1", "2"])
    }
    @Test func testTabRepresentativeKeepsSlotGeometry() throws {
        var layout = Layout(columns: [Column(slots: [Slot(id: "tabs", members: [1, 2], activeMember: 1)], width: 500)])
        let canvas = Rect(x: -1440, y: 20, width: 1440, height: 850)
        let before = try layout.placements(in: canvas)
        layout.columns[0].slots[0].activeMember = 2
        let after = try layout.placements(in: canvas)
        checkEqual(before[0].frame, after[0].frame)
        checkEqual(after.count, 1); checkEqual(after[0].windowID, 2)
    }
    @Test func testInvalidMembershipRejected() {
        let layout = Layout(columns: [Column(slots: [slot(1), slot(1)], width: 400)])
        #expect(throws: (any Error).self) { try layout.validate() }
    }
    @Test func testDenseStackNeverProducesNegativeFrames() throws {
        let layout = Layout(columns: [Column(slots: (1...50).map { slot(UInt32($0)) }, width: 400)])
        let frames = try layout.placements(in: Rect(x: 0, y: 0, width: 800, height: 100))
        checkTrue(frames.allSatisfy { $0.frame.isValid })
        checkEqual(frames.last!.frame.y + frames.last!.frame.height, 100, accuracy: 0.00001)
    }
    @Test func testSectionGroupingKeepsColumnsTogetherAndSnapsBack() throws {
        let layout = Layout(columns: [Column(slots: [slot(1), slot(2)], width: 400), Column(slots: [slot(3)], width: 400), Column(slots: [slot(4)], width: 600)])
        let sections = try Paging.sections(layout, viewportWidth: 1000)
        checkEqual(sections.map(\.slotIDs), [["1", "2", "3"], ["4"]])
        checkEqual(Paging.destination(current: 0, count: 2, translation: -100, velocity: 0, viewportWidth: 1000), 0)
        checkEqual(Paging.destination(current: 0, count: 2, translation: -100, velocity: -800, viewportWidth: 1000), 1)
        checkEqual(Paging.destination(current: 1, count: 2, translation: -900, velocity: -800, viewportWidth: 1000), 1)
    }
    @Test func testCenterUsesVirtualPositionOnNegativeOriginDisplay() throws {
        var layout = Layout(columns: [Column(slots: [slot(1)], width: 400), Column(slots: [slot(2)], width: 400)], focused: "2")
        let canvas = Rect(x: -1000, y: 0, width: 1000, height: 800)
        try layout.center(in: canvas)
        checkEqual(try layout.placements(in: canvas)[1].frame.x, -700)
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T) { #expect(actual == expected) }
private func checkEqual(_ actual: Double, _ expected: Double, accuracy: Double) { #expect(abs(actual - expected) <= accuracy) }
private func checkTrue(_ value: Bool) { #expect(value) }
private func checkNil<T>(_ value: T?) { #expect(value == nil) }
