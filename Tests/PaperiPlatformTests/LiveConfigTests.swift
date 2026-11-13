import Foundation
import Testing
@testable import PaperiPlatform

struct LiveConfigTests {
    @Test func snapshotStyleConfiguration() throws {
        #expect(LiveConfig.GestureConfig().snapshotStyle == .native)
        for json in ["{}", #"{"gesture":{}}"#] {
            let config = try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            #expect(config.gesture.snapshotStyle == .native)
        }
        for style in [LiveConfig.SnapshotStyle.native, .simple] {
            let json = "{\"gesture\":{\"snapshotStyle\":\"\(style.rawValue)\"}}"
            let config = try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            #expect(config.gesture.snapshotStyle == style)
            let encoded = try JSONEncoder().encode(config)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect((object["gesture"] as? [String: Any])?["snapshotStyle"] as? String == style.rawValue)
            #expect(try JSONDecoder().decode(LiveConfig.self, from: encoded) == config)
        }
        for value in [#""fast""#, "true", "42"] {
            let json = "{\"gesture\":{\"snapshotStyle\":\(value)}}"
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            }
        }
        let template = try JSONDecoder().decode(LiveConfig.self, from: Data(LiveConfig.template.utf8))
        #expect(template.gesture.snapshotStyle == .native)
    }

    @Test func tapAction() throws {
        #expect(LiveConfig.GestureConfig().tap == .tray)
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"tap":"none"}}"#.utf8))
        #expect(config.gesture.tap == .none)
        #expect(try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"tap":"lookUp"}}"#.utf8))
        }
    }

    @Test func openAppGesture() throws {
        #expect(LiveConfig.GestureConfig().swipeDownApp == nil)
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"swipeDown":"openApp","swipeDownApp":"com.apple.Terminal"}}"#.utf8))
        #expect(config.gesture.swipeDown == .openApp)
        #expect(config.gesture.swipeDownApp == "com.apple.Terminal")
        #expect(try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config)
        for json in [
            #"{"gesture":{"swipeDown":"openApp"}}"#,
            #"{"gesture":{"swipeDownRight":"openApp"}}"#,
            #"{"gesture":{"swipeDown":"openApp","swipeDownApp":" "}}"#
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            }
        }
    }

    @Test func bottomModes() throws {
        #expect(LiveConfig().bottomDotsVisibility == .auto)
        #expect(try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8)).bottomDotsVisibility == .auto)
        for (legacy, expected) in [("dot", "visible"), ("dots", "visible"), ("thumbnail", "visible"), ("none", "hidden")] {
            let data = Data("{\"bottom\":\"\(legacy)\"}".utf8)
            let config = try JSONDecoder().decode(LiveConfig.self, from: data)
            #expect(config.bottomDotsVisibility.rawValue == expected)
            let encoded = try JSONEncoder().encode(config)
            let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            #expect(object["bottom"] == nil)
            #expect(object["bottomDotsVisibility"] as? String == expected)
        }
        for mode in LiveConfig.BottomDotsVisibility.allCases {
            let data = Data("{\"bottomDotsVisibility\":\"\(mode.rawValue)\"}".utf8)
            let config = try JSONDecoder().decode(LiveConfig.self, from: data)
            #expect(config.bottomDotsVisibility == mode)
            #expect(try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config)
        }
        let precedence = Data(#"{"bottomDotsVisibility":"auto","bottom":"none"}"#.utf8)
        #expect(try JSONDecoder().decode(LiveConfig.self, from: precedence).bottomDotsVisibility == .auto)
        for json in [#"{"bottom":"invalid"}"#, #"{"bottomDotsVisibility":"invalid"}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            }
        }
    }

    @Test func edgeHintColor() throws {
        let defaults = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(defaults.edgeHintColor == LiveConfig().edgeHintColor)
        #expect(defaults.edgeHintColor.alpha == 1)
        #expect(defaults.edgeHintColor.red == defaults.swapHighlightColor.red)
        #expect(defaults.edgeHintColor.green == defaults.swapHighlightColor.green)
        #expect(defaults.edgeHintColor.blue == defaults.swapHighlightColor.blue)
        for color in ["#FF8800", "#11223380"] {
            let config = try JSONDecoder().decode(LiveConfig.self, from: Data("{\"edgeHint\":\"\(color)\"}".utf8))
            #expect(config.edgeHint == color)
            let roundTrip = try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config))
            #expect(roundTrip.edgeHintColor == config.edgeHintColor)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"edgeHint":"invalid"}"#.utf8))
        }
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

    @Test func swipeUpToClose() throws {
        #expect(try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8)).gesture.swipeUpToClose)
        // Omitted gesture keys keep their defaults.
        let off = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"swipeUpToClose":false}}"#.utf8))
        #expect(off.gesture == LiveConfig.GestureConfig(swipeUpToClose: false))
        #expect(off.gesture.tabCloseApps.isEmpty)
        let chrome = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"tabCloseApps":["com.google.Chrome"]}}"#.utf8))
        #expect(chrome.gesture.tabCloseApps == ["com.google.Chrome"])
        #expect(chrome.gesture.swipeUpToClose)
        #expect(chrome.gesture.swipeDown == .newWindow)
        #expect(chrome.gesture.swipeDownRight == .closeTab)
        #expect(chrome.gesture.swipeDownLeft == .minimize)
        let legacyOff = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"swipeDownToMinimize":false}}"#.utf8))
        #expect(legacyOff.gesture.swipeDown == LiveConfig.SwipeDownAction.none)
        let newWindow = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"swipeDown":"minimize"}}"#.utf8))
        #expect(newWindow.gesture.swipeDown == .minimize)
        let roundTrip = try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(newWindow))
        #expect(roundTrip.gesture == newWindow.gesture)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"swipeDown":"close"}}"#.utf8))
        }
        let template = try JSONDecoder().decode(LiveConfig.self, from: Data(LiveConfig.template.utf8))
        #expect(template.gesture == LiveConfig.GestureConfig())
    }

    @Test func focusAfterClose() throws {
        #expect(try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8)).focusAfterClose == .left)
        #expect(LiveConfig().focusAfterClose == .left)
        for value in LiveConfig.FocusAfterClose.allCases {
            let config = try JSONDecoder().decode(LiveConfig.self, from: Data("{\"focusAfterClose\":\"\(value.rawValue)\"}".utf8))
            #expect(config.focusAfterClose == value)
            #expect(try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"focusAfterClose":"up"}"#.utf8))
        }
    }

    @Test func gestureConfiguration() throws {
        let defaults = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(defaults.gesture.enabled == true)
        #expect(defaults.gesture.fingers == 3)
        #expect(defaults.gesture.travel == 0.4)
        #expect(defaults.gesture.columnTravel == 0.3)
        #expect(defaults.gesture.commitThreshold == 0.5)
        #expect(defaults.gesture.flickVelocity == 1.5)
        #expect(defaults.gesture.invert == false)

        let json = #"{"gesture":{"enabled":false,"fingers":4,"travel":0.3,"commitThreshold":0.6,"flickVelocity":2.0,"invert":true}}"#
        let custom = try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
        #expect(custom.gesture.enabled == false)
        #expect(custom.gesture.fingers == 4)
        #expect(custom.gesture.travel == 0.3)
        #expect(custom.gesture.commitThreshold == 0.6)
        #expect(custom.gesture.flickVelocity == 2.0)
        #expect(custom.gesture.invert == true)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"fingers":2}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"travel":0}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"commitThreshold":-0.5}}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"flickVelocity":0}}"#.utf8))
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
