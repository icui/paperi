import Testing
@testable import PaperiCore

struct CoreTests {
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
