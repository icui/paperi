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
        #expect(LiveReconciliation.park(hidden, display: main, otherDisplays: []) == hidden)
        // A display on the left would capture the window: slide it right until
        // just over half stays on its own display, under the visible columns.
        let parked = LiveReconciliation.park(hidden, display: main, otherDisplays: [left])
        #expect(parked == Rect(x: -300 + 16, y: 33, width: 600, height: 851))
        // Visible columns are never moved.
        let visible = Rect(x: 100, y: 33, width: 600, height: 851)
        #expect(LiveReconciliation.park(visible, display: main, otherDisplays: [left]) == visible)
    }

    @Test func peeksMostlyOnANeighbourStayMostlyOnTheirOwnDisplay() {
        // The live layout: built-in display with an external one on its left.
        let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 932)
        let external = CGRect(x: -1280, y: 0, width: 1280, height: 720)
        // External strip: focused column fills it, the next column lies past
        // its right edge, i.e. over the built-in display.
        let hiddenRight = Rect(x: -9, y: 39, width: 1248, height: 673)
        let slid = LiveReconciliation.park(hiddenRight, display: external, otherDisplays: [builtIn])
        #expect(slid == Rect(x: -624 - 16, y: 39, width: 1248, height: 673))
        // Built-in strip: a 160 pt peek whose rest lies over the external display.
        let peekLeft = Rect(x: -1248, y: 38, width: 1408, height: 886)
        #expect(LiveReconciliation.park(peekLeft, display: builtIn, otherDisplays: [external]).x == -704 + 16)
        // Mostly on its own display already: unchanged.
        let mostlyOwn = Rect(x: -200, y: 38, width: 1000, height: 886)
        #expect(LiveReconciliation.park(mostlyOwn, display: builtIn, otherDisplays: [external]) == mostlyOwn)
        // No neighbour on that side: unchanged.
        let right = CGRect(x: 1440, y: 0, width: 1280, height: 720)
        #expect(LiveReconciliation.park(peekLeft, display: builtIn, otherDisplays: [right]) == peekLeft)
    }

    @Test func capturedSliversHideBehindTheFocusedWindow() {
        let builtIn = CGRect(x: 0, y: 0, width: 1440, height: 932)
        let external = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let focused = Rect(x: -1272, y: 39, width: 1248, height: 753)
        let hiddenRight = Rect(x: -9, y: 39, width: 1324, height: 753)
        #expect(LiveReconciliation.park(hiddenRight, display: external, otherDisplays: [builtIn], cover: focused) == focused)
        // A sliver with no neighbour on its side keeps its place.
        let hiddenLeft = Rect(x: -1272 + 1 - 1324, y: 39, width: 1324, height: 753)
        #expect(LiveReconciliation.park(hiddenLeft, display: external, otherDisplays: [builtIn], cover: focused) == hiddenLeft)
    }
}
