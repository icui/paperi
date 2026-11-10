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

    @Test func fitKeepsAWindowInsideTheCanvas() {
        let canvas = Rect(x: 115, y: -761, width: 1264, height: 753)
        #expect(LiveReconciliation.fit(Rect(x: -2512, y: 39, width: 1408, height: 886), into: canvas)
                == Rect(x: 115, y: -761, width: 1264, height: 753))
        let inside = Rect(x: 200, y: -700, width: 600, height: 500)
        #expect(LiveReconciliation.fit(inside, into: canvas) == inside)
    }
}
