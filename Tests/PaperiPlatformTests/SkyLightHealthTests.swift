import Foundation
import Testing
@testable import PaperiPlatform

struct SkyLightHealthTests {
    private let healthy: [[String: Any]] = [[
        "Display Identifier": "Main",
        "Current Space": ["ManagedSpaceID": NSNumber(value: 1)],
        "Spaces": [["ManagedSpaceID": NSNumber(value: 1)], ["ManagedSpaceID": NSNumber(value: 5)]]
    ]]

    private func check(missing: [String] = [], connection: Int32 = 1, spaces: Any?, screens: Int = 1,
                       type: @escaping (UInt64) -> Int32 = { $0 == 5 ? 4 : 0 }) -> String? {
        SkyLightHealth.problem(missingFunctions: missing, connection: connection, displaySpaces: spaces,
                               screenCount: screens, spaceType: type)
    }

    @Test func healthyDataPasses() {
        #expect(check(spaces: healthy) == nil)
    }

    @Test func missingFunctionsAreNamed() {
        let problem = check(missing: ["SLSCopyManagedDisplaySpaces", "_AXUIElementGetWindow"], spaces: healthy)
        #expect(problem?.contains("SLSCopyManagedDisplaySpaces, _AXUIElementGetWindow") == true)
        #expect(problem.map(SkyLightHealth.isProblem) == true)
    }

    @Test func noConnectionOrNoData() {
        #expect(check(connection: 0, spaces: healthy)?.contains("SLSMainConnectionID returned 0") == true)
        #expect(check(spaces: nil)?.contains("returned nothing") == true)
        #expect(check(spaces: "nope")?.contains("unexpected") == true)
        #expect(check(spaces: [[String: Any]](), screens: 2)?.contains("no displays although 2") == true)
    }

    @Test func noScreensIsNotAnInterfaceProblem() {
        #expect(check(spaces: nil, screens: 0) == nil)
    }

    @Test func renamedKeysAreReported() {
        var renamed = healthy
        renamed[0]["Display Identifier"] = nil
        renamed[0]["DisplayUUID"] = "Main"
        #expect(check(spaces: renamed)?.contains("no “Display Identifier”; keys: Current Space, DisplayUUID, Spaces") == true)

        var noIDs = healthy
        noIDs[0]["Spaces"] = [["id64": NSNumber(value: 1)]]
        #expect(check(spaces: noIDs)?.contains("no Spaces with a “ManagedSpaceID”") == true)
    }

    @Test func changedTypeCodesAreReported() {
        #expect(check(spaces: healthy, type: { _ in 7 })?.contains("only [7]") == true)
    }

    @Test func displayProblemsAreNotCompatibilityProblems() {
        #expect(!SkyLightHealth.isProblem("Paperi requires “Displays have separate Spaces”."))
    }
}
