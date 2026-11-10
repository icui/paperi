import Foundation
import Testing
@testable import PaperiPlatform

struct LiveConfigTests {
    @Test func snapshotExperimentIsOptIn() throws {
        #expect(LiveConfig().experimentalSnapshotScroll == nil)
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"experimentalSnapshotScroll":true}"#.utf8))
        #expect(config.experimentalSnapshotScroll == true)
        let restored = try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.experimentalSnapshotScroll == true)
    }

    @Test func focusDuration() throws {
        for duration in [0.0, 0.14, 1.0] {
            let config = try JSONDecoder().decode(LiveConfig.self, from: Data("{\"focusScrollDuration\":\(duration)}".utf8))
            #expect(config.focusScrollDuration == duration)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"focusScrollDuration":-1}"#.utf8))
        }
    }

    @Test func defaultsManageRegularAppsExceptSystemUI() {
        let config = LiveConfig()
        #expect(config.manages(bundleID: "com.tinyspeck.slackmacgap", regular: true))
        #expect(!config.manages(bundleID: "com.example.agent", regular: false))
        #expect(!config.manages(bundleID: "com.apple.controlcenter", regular: true))
        #expect(!config.manages(bundleID: "dev.paperi.app", regular: true))
        #expect(!config.manages(bundleID: nil, regular: true))
    }

    @Test func includeExcludeAndFloatRules() throws {
        let json = #"{"exclude":["us.zoom.xos"],"float":[{"app":"com.apple.finder","titleContains":"info"},{"app":"com.apple.calculator"}]}"#
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
        #expect(config.include == nil && config.singleton.isEmpty)
        #expect(!config.manages(bundleID: "us.zoom.xos", regular: true))
        #expect(config.floats(bundleID: "com.apple.finder", title: "Downloads Info"))
        #expect(!config.floats(bundleID: "com.apple.finder", title: "Downloads"))
        #expect(config.floats(bundleID: "com.apple.calculator", title: nil))
        var only = LiveConfig(include: ["com.apple.TextEdit"])
        #expect(only.manages(bundleID: "com.apple.TextEdit", regular: true))
        #expect(!only.manages(bundleID: "com.apple.finder", regular: true))
        only.include = ["com.example.agent"]
        #expect(only.manages(bundleID: "com.example.agent", regular: false))
    }
}
