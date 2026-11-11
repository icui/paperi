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
    // Columns 300 wide, gap 8, offset 0 on a canvas at x 0: centres 150, 458, 766.
    func dragStrip() -> Layout {
        Layout(columns: (1...3).map { Column(slots: [slot(UInt32($0))], width: 300) }, focused: "2")
    }
    @Test func testSwapTargetsCoverVisibleNeighboursAndReachableSlivers() throws {
        let canvas = Rect(x: 0, y: 0, width: 1000, height: 800)
        let targets = try dragStrip().swapTargets(slotID: "2", in: canvas)   // columns at 0, 308, 616
        checkEqual(targets.map(\.slotID), ["1", "3"])
        checkEqual(targets[0].region, Rect(x: 0, y: 0, width: 300, height: 800))
        checkEqual(targets[1].region, Rect(x: 616, y: 0, width: 300, height: 800))
        checkTrue(targets[0].contains(x: 299, y: 400) && !targets[0].contains(x: 300, y: 400))
        checkEqual(try dragStrip().swapTargets(slotID: "1", in: canvas).map(\.slotID), ["2"])
        // Column 1 shows 5 px at the left edge, column 3 a 1 px sliver at the right:
        // both widen to the 24 px edge zone.
        let scrolled = Layout(columns: [Column(slots: [slot(1)], width: 300), Column(slots: [slot(2)], width: 984),
                                        Column(slots: [slot(3)], width: 300)], focused: "2", offset: -295)
        let edges = try scrolled.swapTargets(slotID: "2", in: canvas)
        checkEqual(edges[0].region, Rect(x: 0, y: 0, width: 24, height: 800))
        checkEqual(edges[1].region, Rect(x: 976, y: 0, width: 24, height: 800))
    }
    @Test func testSwapTargetsIncludeStackedRows() throws {
        let canvas = Rect(x: 0, y: 0, width: 1000, height: 808)
        // [1] [2 over 3] [4 over 5]: rows 400 high with an 8 px gap.
        let layout = Layout(columns: [Column(slots: [slot(1)], width: 300), Column(slots: [slot(2), slot(3)], width: 300),
                                      Column(slots: [slot(4), slot(5)], width: 300)], focused: "2")
        let targets = try layout.swapTargets(slotID: "2", in: canvas)
        checkEqual(targets.map(\.slotID), ["1", "3", "4", "5"])
        checkEqual(targets[1].region, Rect(x: 308, y: 408, width: 300, height: 400))
        checkEqual(targets[3].region, Rect(x: 616, y: 408, width: 300, height: 400))
        checkTrue(targets[2].contains(x: 700, y: 100) && !targets[2].contains(x: 700, y: 500))
    }
    @Test func testSwapSlotsMovesSingleColumnsWholeAndExchangesStackedRows() throws {
        var layout = Layout(columns: [Column(slots: [slot(1)], width: 300), Column(slots: [slot(2)], width: 500),
                                      Column(slots: [slot(3), slot(4)], width: 400, weights: [2, 1])], focused: "2")
        checkTrue(layout.swapSlots("2", "1"))   // single-window columns: widths travel
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["2"], ["1"], ["3", "4"]])
        checkEqual(layout.columns.map(\.width), [500, 300, 400])
        checkTrue(layout.swapSlots("1", "4"))   // into a stack: positions (and sizes) are exchanged
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["2"], ["4"], ["3", "1"]])
        checkEqual(layout.columns.map(\.width), [500, 300, 400])
        checkEqual(layout.columns[2].weights, [2, 1])
        checkTrue(layout.swapSlots("3", "1"))   // within a stack
        checkEqual(layout.columns[2].slots.map(\.id), ["1", "3"])
        checkEqual(layout.focused, "2")
        checkTrue(!layout.swapSlots("2", "2") && !layout.swapSlots("2", "9"))
        try layout.validate()
    }
    @Test func testDropZonesStackOtherColumnsAndSplitOutOwnStack() throws {
        let canvas = Rect(x: 0, y: 0, width: 1000, height: 808)
        // [1] [2 over 3]: dragging 2, slot 1 is another column, slot 3 its own stack.
        let layout = Layout(columns: [Column(slots: [slot(1)], width: 300), Column(slots: [slot(2), slot(3)], width: 300)],
                            focused: "2")
        let targets = try layout.swapTargets(slotID: "2", in: canvas)
        checkEqual(targets.map(\.sameColumn), [false, true])
        let other = targets[0]   // 0...300 × 0...808
        checkEqual(other.action(x: 150, y: 100), .stackAbove)
        checkEqual(other.action(x: 150, y: 202), .swap)
        checkEqual(other.action(x: 150, y: 605), .swap)
        checkEqual(other.action(x: 150, y: 606), .stackBelow)
        checkEqual(other.action(x: 10, y: 400), .swap)   // left/right do not split out of another column
        checkTrue(other.action(x: 400, y: 400) == nil)
        let own = targets[1]     // 308...608 × 408...808
        checkEqual(own.action(x: 380, y: 410), .newColumnLeft)
        checkEqual(own.action(x: 458, y: 800), .swap)
        checkEqual(own.action(x: 533, y: 600), .newColumnRight)
    }
    @Test func testDropStacksSplittingTargetHeightAndRemovesEmptiedColumn() throws {
        let base = Layout(columns: [Column(slots: [slot(1)], width: 300), Column(slots: [slot(2)], width: 500),
                                    Column(slots: [slot(3), slot(4)], width: 400, weights: [300, 100])], focused: "2")
        var layout = base
        checkTrue(layout.drop("2", on: "1", action: .stackAbove))
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["2", "1"], ["3", "4"]])
        checkEqual(layout.columns[0].weights, [0.5, 0.5])
        checkEqual(layout.columns.map(\.width), [300, 400])
        checkEqual(layout.focused, "2")
        try layout.validate()
        layout = base
        checkTrue(layout.drop("2", on: "3", action: .stackBelow))
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["1"], ["3", "2", "4"]])
        checkEqual(layout.columns[1].weights, [150, 150, 100])
        try layout.validate()
        layout = base
        checkTrue(layout.drop("2", on: "1", action: .swap))
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["2"], ["1"], ["3", "4"]])
    }
    @Test func testDropSplitsOutOfOwnStackIntoNewColumn() throws {
        let base = Layout(columns: [Column(slots: [slot(1)], width: 300),
                                    Column(slots: [slot(2), slot(3), slot(4)], width: 400, weights: [1, 2, 3])], focused: "3")
        var layout = base
        checkTrue(layout.drop("3", on: "2", action: .newColumnLeft))
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["1"], ["3"], ["2", "4"]])
        checkEqual(layout.columns[2].weights, [1, 3])
        checkEqual(layout.columns.map(\.width), [300, 400, 400])
        try layout.validate()
        layout = base
        checkTrue(layout.drop("3", on: "4", action: .newColumnRight))
        checkEqual(layout.columns.map { $0.slots.map(\.id) }, [["1"], ["2", "4"], ["3"]])
        try layout.validate()
        // A window alone in its column has no stack to leave.
        layout = base
        checkTrue(!layout.drop("1", on: "2", action: .newColumnRight) && !layout.drop("2", on: "2", action: .stackAbove))
        checkEqual(layout, base)
    }
    @Test func testHexColorParsesRGBAndRGBA() {
        checkEqual(HexColor("#0A84FF4D"), HexColor("0a84ff4d"))
        checkEqual(HexColor("#FF0000")?.alpha, 1)
        checkEqual(HexColor("#00000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.0001)
        checkTrue(HexColor("blue") == nil && HexColor("#12345") == nil)
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
