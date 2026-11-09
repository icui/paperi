import Testing
import PaperiCore
@testable import PaperiPlatform

struct DisplaySpaceCoordinatorTests {
    @MainActor @Test func multiDisplayCoordinatorSeparatesSpacesNumbersThemAndTransfersTabContainersAtomically() throws {
        let primary = DisplaySpaceTopology(displayUUID: "D1", canvas: Rect(x: 0, y: 25, width: 1440, height: 875),
            spaces: [.init(id: 1, isUserSpace: true), .init(id: 374, isUserSpace: false), .init(id: 378, isUserSpace: true)],
            activeSpaceID: 1)
        let external = DisplaySpaceTopology(displayUUID: "D2", canvas: Rect(x: -1920, y: 0, width: 1920, height: 1080),
            spaces: [.init(id: 501, isUserSpace: true), .init(id: 502, isUserSpace: true)],
            activeSpaceID: 501)
        let coordinator = DisplaySpaceCoordinator(ownerPID: 42, displays: [primary, external],
                                                  ownership: .applicationLocalFixture)
        #expect(coordinator.sessions.keys.sorted() == [1, 378, 501, 502])
        #expect(coordinator.numberedUserSpace(1) == 1)
        #expect(coordinator.numberedUserSpace(2) == 378)
        #expect(coordinator.numberedUserSpace(3) == 501)
        #expect(coordinator.numberedUserSpace(4) == 502)
        #expect(coordinator.numberedUserSpace(5) == nil)
        #expect(coordinator.display(forSpace: 501)?.displayUUID == "D2")

        let eligible = WindowPolicy.classify(WindowFacts(bundleID: "test", role: "AXWindow", subrole: "AXStandardWindow",
            isRoot: true, movable: true, resizable: true, level: 0))
        #expect(try coordinator.admitTabs(members: [101, 102], active: 102, ownerPID: 42, spaceID: 1, classification: eligible))
        #expect(try coordinator.insertSingleton(windowID: 201, ownerPID: 42, spaceID: 1, classification: eligible))
        #expect(try coordinator.insertSingleton(windowID: 301, ownerPID: 42, spaceID: 501, classification: eligible))

        let slotID = coordinator.sessions[1]?.slots[102]
        let originalWidth = coordinator.sessions[1]?.state.layout.columns[0].width
        #expect(slotID != nil && originalWidth != nil)

        // Move the 2-tab container from Space 1 (Display 1) to Space 501 (Display 2).
        let moved = try coordinator.transferContainer(containing: 101, to: 501, classification: eligible)
        #expect(moved?.source == 1 && moved?.destination == 501)
        #expect(coordinator.spaceForWindow[101] == 501 && coordinator.spaceForWindow[102] == 501)
        #expect(coordinator.sessions[1]?.slots[101] == nil && coordinator.sessions[1]?.slots[201] != nil)
        #expect(coordinator.sessions[501]?.slots[101] == slotID && coordinator.sessions[501]?.slots[102] == slotID)
        let destIndex = coordinator.sessions[501]?.state.layout.index(of: slotID!)
        #expect(destIndex != nil)
        #expect(coordinator.sessions[501]?.state.layout.columns[destIndex!.column].width == originalWidth)

        // Placements on Display 2 use its negative-origin canvas without affecting Display 1.
        let d1Placements = try coordinator.sessions[1]!.state.layout.placements(in: coordinator.sessions[1]!.canvas)
        let d2Placements = try coordinator.sessions[501]!.state.layout.placements(in: coordinator.sessions[501]!.canvas)
        #expect(d1Placements.map(\.windowID) == [201])
        #expect(Set(d2Placements.map(\.windowID)) == [301, 102])
        #expect(d2Placements.allSatisfy { $0.frame.x < 0 })

        coordinator.stop()
        #expect(!coordinator.running && coordinator.sessions.isEmpty && coordinator.spaceForWindow.isEmpty)
    }
}
