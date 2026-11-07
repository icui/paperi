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
}
