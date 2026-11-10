import CoreGraphics
import Testing
import PaperiCore
@testable import PaperiPlatform

@MainActor struct LiveReconciliationTests {
    let canvas = Rect(x: 8, y: 33, width: 1424, height: 851)
    var eligible: Classification { WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow",
        subrole: "AXStandardWindow", isRoot: true, movable: true, resizable: true, level: 0)) }

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

    @Test func hiddenColumnsAvoidNeighbouringDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let hidden = Rect(x: canvas.x + 1 - 600, y: 33, width: 600, height: 851)
        // No neighbour: keep the PaperWM sliver.
        #expect(LiveReconciliation.park(hidden, canvas: canvas, display: main, otherDisplays: []) == hidden)
        // A display on the left would capture the window: park below instead.
        let parked = LiveReconciliation.park(hidden, canvas: canvas, display: main, otherDisplays: [left])
        #expect(parked.y == 899 && parked.x == canvas.x)
        // Visible columns are never parked.
        let visible = Rect(x: 100, y: 33, width: 600, height: 851)
        #expect(LiveReconciliation.park(visible, canvas: canvas, display: main, otherDisplays: [left]) == visible)
    }

    @Test func partlyVisibleColumnsMostlyOnANeighbourAreParked() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: -1280, y: 0, width: 1280, height: 720)
        let right = CGRect(x: 1440, y: 0, width: 1280, height: 720)
        // 160 pt peek on the main display, the rest on the left display: the
        // window server would move it there, so it is parked below instead.
        let peekLeft = Rect(x: -1248, y: 33, width: 1408, height: 851)
        let parked = LiveReconciliation.park(peekLeft, canvas: canvas, display: main, otherDisplays: [left])
        #expect(parked == Rect(x: canvas.x, y: 899, width: 1408, height: 851))
        let peekRight = Rect(x: canvas.x + canvas.width - 160, y: 33, width: 1408, height: 851)
        let parkedRight = LiveReconciliation.park(peekRight, canvas: canvas, display: main, otherDisplays: [right])
        #expect(parkedRight == Rect(x: canvas.x + canvas.width - 1408, y: 899, width: 1408, height: 851))
        // Mostly on its own display: the peek stays.
        let mostlyOwn = Rect(x: -200, y: 33, width: 1000, height: 851)
        #expect(LiveReconciliation.park(mostlyOwn, canvas: canvas, display: main, otherDisplays: [left]) == mostlyOwn)
        // No neighbour on that side: the peek stays.
        #expect(LiveReconciliation.park(peekLeft, canvas: canvas, display: main, otherDisplays: [right]) == peekLeft)
    }
}
