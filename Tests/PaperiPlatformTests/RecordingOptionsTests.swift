import Testing
@testable import PaperiPlatform

struct RecordingOptionsTests {
    @Test func defaultAndFilteredRecording() throws {
        let defaults = try RecordingOptions(arguments: [])
        #expect(defaults.seconds == 30)
        #expect(defaults.bundleIDs == nil)
        let filtered = try RecordingOptions(arguments: ["--bundle-id", "test.one", "0.5",
                                                       "--bundle-id", "test.two"])
        #expect(filtered.seconds == 0.5)
        #expect(filtered.bundleIDs == ["test.one", "test.two"])
    }

    @Test func rejectsInvalidDurationAndFilterArguments() {
        for arguments in [["0"], ["-1"], ["301"], ["nan"], ["inf"], ["1", "2"],
                          ["--unknown"], ["--bundle-id"], ["--bundle-id", ""],
                          ["--bundle-id", "--unknown"]] {
            #expect(throws: RecordingOptions.InvalidArguments.self) {
                try RecordingOptions(arguments: arguments)
            }
        }
    }

    @Test func tabEvidenceRequiresOneExplicitApplication() throws {
        let options = try RecordingOptions(arguments: ["--tab-evidence", "--bundle-id", "test.one"])
        #expect(options.includeTabEvidence)
        #expect(options.bundleIDs == ["test.one"])
        #expect(try !RecordingOptions(arguments: []).includeTabEvidence)
        for arguments in [["--tab-evidence"], ["--tab-evidence", "--bundle-id", "test.one", "--bundle-id", "test.two"],
                          ["--tab-evidence", "--tab-evidence", "--bundle-id", "test.one"]] {
            #expect(throws: RecordingOptions.InvalidArguments.self) { try RecordingOptions(arguments: arguments) }
        }
    }

    @Test func restartMustOccurStrictlyWithinRecordingDuration() throws {
        #expect(try RecordingOptions(arguments: []).restartAfter == nil)
        #expect(try RecordingOptions(arguments: ["--restart-after", "2.5", "10"]).restartAfter == 2.5)
        for arguments in [["--restart-after"], ["--restart-after", "0"], ["--restart-after", "-1"],
                          ["--restart-after", "nan"], ["--restart-after", "inf"],
                          ["--restart-after", "30"], ["10", "--restart-after", "11"],
                          ["--restart-after", "1", "--restart-after", "2"]] {
            #expect(throws: RecordingOptions.InvalidArguments.self) { try RecordingOptions(arguments: arguments) }
        }
    }

    @Test func windowEvidenceRequiresOneExplicitApplication() throws {
        #expect(try !RecordingOptions(arguments: []).includeWindowEvidence)
        let combined = try RecordingOptions(arguments: ["--window-evidence", "--tab-evidence", "--bundle-id", "test.one"])
        #expect(combined.includeWindowEvidence && combined.includeTabEvidence)
        for arguments in [["--window-evidence"], ["--window-evidence", "--window-evidence", "--bundle-id", "test.one"],
                          ["--window-evidence", "--bundle-id", "test.one", "--bundle-id", "test.two"]] {
            #expect(throws: RecordingOptions.InvalidArguments.self) { try RecordingOptions(arguments: arguments) }
        }
    }
}
