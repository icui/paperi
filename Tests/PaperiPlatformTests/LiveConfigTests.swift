import Foundation
import Testing
@testable import PaperiPlatform

struct LiveConfigTests {
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

    @Test func managedDisplayDefaultsToMainAndMatchesUUIDOrName() throws {
        let displays = [LiveConfig.DisplayInfo(uuid: "37D8-BUILTIN", name: "Built-in Retina Display", isMain: true),
                        LiveConfig.DisplayInfo(uuid: "D55E-EXTERNAL", name: "InnoView", isMain: false)]
        func pick(_ spec: String?) -> (Set<String>, Bool) {
            var config = LiveConfig(); config.display = spec
            let r = config.managedDisplays(displays); return (r.uuids, r.matched)
        }
        #expect(pick(nil) == (["37D8-BUILTIN"], true))
        #expect(pick("main") == (["37D8-BUILTIN"], true))
        #expect(pick("all") == (["37D8-BUILTIN", "D55E-EXTERNAL"], true))
        #expect(pick("innoview") == (["D55E-EXTERNAL"], true))
        #expect(pick("d55e-external") == (["D55E-EXTERNAL"], true))
        // Unknown or disconnected: fall back to the main display, flagged.
        #expect(pick("Studio Display") == (["37D8-BUILTIN"], false))
        let decoded = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"display": "InnoView"}"#.utf8))
        #expect(decoded.display == "InnoView")
    }
}
