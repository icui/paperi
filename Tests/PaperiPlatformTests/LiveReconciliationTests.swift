import CoreGraphics
import Testing
import PaperiCore
@testable import PaperiPlatform

@MainActor struct LiveReconciliationTests {
    @Test func edgeBounceReturnsToLayoutWithoutResizing() {
        let frame = Rect(x: 100, y: 40, width: 700, height: 800)
        for direction in [Direction.left, .right, .up, .down] {
            #expect(LiveReconciliation.edgeBounce(frame, toward: direction, progress: 0) == frame)
            #expect(LiveReconciliation.edgeBounce(frame, toward: direction, progress: 1) == frame)
            let peak = LiveReconciliation.edgeBounce(frame, toward: direction, progress: 0.5)
            #expect(peak.width == frame.width && peak.height == frame.height)
            switch direction {
            case .left: #expect(peak.x == 124 && peak.y == 40)
            case .right: #expect(peak.x == 76 && peak.y == 40)
            case .up: #expect(peak.x == 100 && peak.y == 64)
            case .down: #expect(peak.x == 100 && peak.y == 16)
            }
        }
    }

    @Test func bouncingStripPreservesWindowSpacingAndIsBounded() {
        let left = Rect(x: 8, y: 40, width: 600, height: 800)
        let right = Rect(x: 616, y: 40, width: 800, height: 800)
        for progress in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
            let a = LiveReconciliation.edgeBounce(left, toward: .right, progress: progress)
            let b = LiveReconciliation.edgeBounce(right, toward: .right, progress: progress)
            #expect(abs((b.x - a.x) - (right.x - left.x)) < 0.001)
            #expect(a.x <= left.x && a.x >= left.x - 24)
        }
    }

    @Test func swipeInterpolationClampsAndPreservesSizes() {
        let start = Rect(x: -200, y: 40, width: 500, height: 700)
        let end = Rect(x: 300, y: 60, width: 800, height: 900)
        #expect(LiveReconciliation.interpolate([1: start], [1: end], progress: 0.5)[1]
                == Rect(x: 50, y: 50, width: 500, height: 700))
        #expect(LiveReconciliation.interpolate([1: start], [1: end], progress: -3)[1] == start)
        #expect(LiveReconciliation.interpolate([1: start], [1: end], progress: .nan)[1] == start)
        #expect(LiveReconciliation.interpolate([1: start], [:], progress: 1)[1] == start)
        #expect(LiveReconciliation.interpolate([1: start], [1: end], progress: 3)[1]?.x == 300)
    }

    @Test func swipeInterpolationMovesEveryImageAtTheStripSpeed() {
        // Strip scrolls 600 pt left. Window 2 leaves view into the left tuck;
        // window 3 enters from the right tuck; window 4 stays tucked.
        let canvas = Rect(x: 0, y: 0, width: 1000, height: 800)
        let starts: [UInt32: Rect] = [1: Rect(x: 700, y: 0, width: 500, height: 800),
                                      2: Rect(x: 100, y: 0, width: 300, height: 800),
                                      3: Rect(x: 999, y: 0, width: 500, height: 800),
                                      4: Rect(x: -499, y: 0, width: 500, height: 800)]
        let ends: [UInt32: Rect] = [1: Rect(x: 100, y: 0, width: 500, height: 800),
                                    2: Rect(x: -299, y: 0, width: 300, height: 800),
                                    3: Rect(x: 600, y: 0, width: 500, height: 800),
                                    4: Rect(x: -499, y: 0, width: 500, height: 800)]
        var previous = starts
        for step in 1...10 {
            let frames = LiveReconciliation.interpolate(starts, ends, progress: Double(step) / 10, canvas: canvas)
            for (wid, frame) in frames {
                let moved = previous[wid]!.x - frame.x
                // No image ever outruns the strip (60 pt per step) or moves backwards.
                #expect(moved >= -0.001 && moved <= 60.001)
            }
            previous = frames
        }
        #expect(previous == ends)
        // Leaving: moves with the strip from the start, then holds at the tuck.
        let half = LiveReconciliation.interpolate(starts, ends, progress: 0.5, canvas: canvas)
        #expect(abs(half[1]!.x - 400) < 0.001 && abs(half[2]!.x - -200) < 0.001)
        // Entering: holds at the tuck, then moves with the strip into place.
        #expect(abs(half[3]!.x - 900) < 0.001 && half[4]?.x == -499)
        #expect(LiveReconciliation.interpolate(starts, ends, progress: 0.3, canvas: canvas)[3]?.x == 999)
        let late = LiveReconciliation.interpolate(starts, ends, progress: 0.9, canvas: canvas)
        #expect(abs((late[3]!.x - ends[3]!.x) - (late[1]!.x - ends[1]!.x)) < 0.001)
    }

    @Test func handoffNeedsCompleteStableObservationsAndReportsClamping() {
        let target = Rect(x: -500, y: 40, width: 600, height: 700)
        let actual = Rect(x: -490, y: 40, width: 600, height: 700)
        #expect(!LiveReconciliation.handoff(previous: [:], current: [1: actual], targets: [1: target]).settled)
        let result = LiveReconciliation.handoff(previous: [1: actual], current: [1: actual], targets: [1: target])
        #expect(result.settled)
        #expect(result.landing[1] == actual)
        #expect(result.maxDeviation == 10)
        #expect(!LiveReconciliation.handoff(previous: [1: actual], current: [:], targets: [1: target]).settled)
        var resized = actual; resized.width += 10
        #expect(!LiveReconciliation.handoff(previous: [1: actual], current: [1: resized], targets: [1: target]).settled)
    }

    @Test func swipeCommandRejectsInvalidTravelAndVerticalDirections() {
        #expect(LiveCommand.validate(["swipe", "right"]) == nil)
        #expect(LiveCommand.validate(["swipe", "left", "0.3"]) == nil)
        #expect(LiveCommand.validate(["swipe", "up"]) == nil)
        for args in [["swipe"], ["swipe", "down"], ["swipe", "left", "nan"],
                     ["swipe", "right", "0"], ["swipe", "right", "2"]] {
            #expect(LiveCommand.validate(args) != nil)
        }
    }

    let canvas = Rect(x: 8, y: 33, width: 1424, height: 851)
    var eligible: Classification { WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow",
        subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true, level: 0)) }

    @Test func focusTargetsIncludeOrdinaryWindowsAndTuckedEdges() throws {
        let layout = Layout(columns: (1...5).map { id in
            Column(slots: [Slot(id: "slot\(id)", members: [UInt32(id)], activeMember: UInt32(id))], width: 600)
        })
        let placements = try layout.placements(in: canvas, gap: 8)
        let targets = LiveReconciliation.focusTargets(placements, canvas: canvas, screenInset: 8)
        let tucked = LiveReconciliation.tuck(placements.map { ($0.windowID, $0.frame) }, canvas: canvas, screenInset: 8)
        #expect(targets.count == placements.count)
        #expect(targets[1] == placements[0].frame)
        #expect(targets[2] == placements[1].frame)
        for placement in placements { #expect(targets[placement.windowID] == (tucked[placement.windowID] ?? placement.frame)) }
        #expect(!tucked.isEmpty)
    }

    @Test func destroyedMembersLeaveContainersInPlace() {
        let slots = [Slot(id: "a", members: [1, 2, 3], activeMember: 2), Slot(id: "b", members: [4], activeMember: 4)]
        #expect(LiveReconciliation.partitions(removing: [2], from: slots) ==
                [.init(members: [1, 3], active: 1), .init(members: [4], active: 4)])
        #expect(LiveReconciliation.partitions(removing: [4], from: slots) == [.init(members: [1, 2, 3], active: 2)])
        #expect(LiveReconciliation.identityPartitions(slots, excluding: [3]) == [.init(members: [4], active: 4)])
    }

    @Test func multiAppSessionKeepsOtherAppsDuringTabReconciliation() throws {
        let coordinator = DisplaySpaceCoordinator(ownerPIDs: [10], displays: [
            DisplaySpaceTopology(displayUUID: "Main", canvas: canvas, spaces: [.init(id: 7, isUserSpace: true)], activeSpaceID: 7)
        ])
        coordinator.addOwner(20)
        #expect(try coordinator.insertSingleton(windowID: 1, ownerPID: 10, spaceID: 7, classification: eligible))
        #expect(try coordinator.insertSingleton(windowID: 2, ownerPID: 20, spaceID: 7, classification: eligible))
        #expect(try !coordinator.insertSingleton(windowID: 3, ownerPID: 30, spaceID: 7, classification: eligible))
        // App 20 grows a native tab (window 5) while app 10's slot is retained by identity.
        let session = coordinator.sessions[7]!
        let others = LiveReconciliation.identityPartitions(session.state.layout.columns.flatMap(\.slots), excluding: [2])
        #expect(try coordinator.reconcileTabs(in: 7, partitions: [.init(members: [2, 5], active: 5)] + others,
                                              destroyed: [], classification: eligible, admitted: [5]))
        #expect(session.state.layout.columns.count == 2)
        #expect(session.slots[5] == session.slots[2])
        #expect(try coordinator.removeContainer(containing: 5, classification: eligible).sorted() == [2, 5])
        #expect(session.state.layout.columns.map { $0.slots[0].members } == [[1]])
        #expect(coordinator.spaceForWindow[2] == nil)
    }

    @Test func displayUpdatesKeepLayoutAndAdoptCanvas() throws {
        let display = DisplaySpaceTopology(displayUUID: "Main", canvas: canvas, spaces: [.init(id: 7, isUserSpace: true)], activeSpaceID: 7)
        let coordinator = DisplaySpaceCoordinator(ownerPIDs: [10], displays: [display])
        try coordinator.insertSingleton(windowID: 1, ownerPID: 10, spaceID: 7, classification: eligible)
        let wider = Rect(x: 8, y: 33, width: 2000, height: 1000)
        coordinator.updateDisplays([DisplaySpaceTopology(displayUUID: "Main", canvas: wider,
            spaces: [.init(id: 7, isUserSpace: true), .init(id: 9, isUserSpace: true)], activeSpaceID: 9)])
        #expect(coordinator.sessions[7]?.canvas == wider)
        #expect(coordinator.sessions[7]?.slots[1] != nil)
        #expect(coordinator.sessions[9] != nil)
    }

    @Test func fitKeepsAWindowInsideTheCanvas() {
        let canvas = Rect(x: 115, y: -761, width: 1264, height: 753)
        #expect(LiveReconciliation.fit(Rect(x: -2512, y: 39, width: 1408, height: 886), into: canvas)
                == Rect(x: 115, y: -761, width: 1264, height: 753))
        let inside = Rect(x: 200, y: -700, width: 600, height: 500)
        #expect(LiveReconciliation.fit(inside, into: canvas) == inside)
    }

    @Test func edgeGroupsListColumnsPastEachEdgeNearestFirst() {
        let canvas = Rect(x: 8, y: 38, width: 1424, height: 886)
        func p(_ id: UInt32, _ x: Double, _ w: Double) -> (window: UInt32, frame: Rect) {
            (id, Rect(x: x, y: 38, width: w, height: 886))
        }
        let placements = [p(1, -1399, 1408), p(2, -1044, 1248), p(3, 212, 1212), p(4, 1264, 1212), p(5, 1431, 1408)]
        #expect(LiveReconciliation.edgeGroups(placements, canvas: canvas) == [[2, 1], [4, 5]])
        // A single column past an edge overlaps nothing.
        #expect(LiveReconciliation.edgeGroups([p(3, 212, 1212), p(4, 1264, 1212)], canvas: canvas).isEmpty)
    }

    @Test func columnsBeyondTheNearestArePushedToTheScreenEdge() {
        let canvas = Rect(x: 8, y: 38, width: 1424, height: 886)
        let frames: [(window: UInt32, frame: Rect)] = [
            (1, Rect(x: -1399, y: 38, width: 1408, height: 886)),   // left sliver behind the peek
            (2, Rect(x: -1044, y: 38, width: 1248, height: 886)),   // left peek (nearest)
            (3, Rect(x: 212, y: 38, width: 1212, height: 886)),     // focused
            (4, Rect(x: 1431, y: 38, width: 1408, height: 886)),    // right sliver (alone)
        ]
        let tucked = LiveReconciliation.tuck(frames, canvas: canvas, screenInset: 8)
        #expect(tucked == [1: Rect(x: 0 - 1408 + 1, y: 38, width: 1408, height: 886)])
        let right = LiveReconciliation.tuck([(5, Rect(x: 1264, y: 38, width: 1212, height: 886)),
                                             (6, Rect(x: 1431, y: 38, width: 1408, height: 886))],
                                            canvas: canvas, screenInset: 8)
        #expect(right == [6: Rect(x: 1439, y: 38, width: 1408, height: 886)])
    }
}
