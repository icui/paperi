import Foundation
import Testing
@testable import PaperiPlatform

struct LiveConfigTests {
    @Test func zoomUsesIndependentWindowsByDefault() throws {
        var config = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(config.usesSingletonWindows(bundleID: "us.zoom.xos"))
        #expect(!config.usesSingletonWindows(bundleID: "com.apple.Terminal"))
        #expect(!config.usesSingletonWindows(bundleID: nil))
        config.strictTabDetection = ["us.zoom.xos"]
        #expect(config.usesSingletonWindows(bundleID: "us.zoom.xos"))
        config.strictTabDetection = ["*"]
        #expect(config.usesSingletonWindows(bundleID: "us.zoom.xos"))
        config.singletonExclude = ["us.zoom.xos"]
        #expect(!config.usesSingletonWindows(bundleID: "us.zoom.xos"))
        config.singleton = ["us.zoom.xos", "test.app"]
        #expect(config.usesSingletonWindows(bundleID: "us.zoom.xos"))
        #expect(config.usesSingletonWindows(bundleID: "test.app"))
    }

    @Test func singletonOverridesDecodeAndRoundTrip() throws {
        let json = Data(#"{"singleton":["test.app"],"singletonExclude":["us.zoom.xos"]}"#.utf8)
        let config = try JSONDecoder().decode(LiveConfig.self, from: json)
        #expect(!config.usesSingletonWindows(bundleID: "us.zoom.xos"))
        #expect(config.usesSingletonWindows(bundleID: "test.app"))
        let restored = try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.singletonExclude == ["us.zoom.xos"])
        #expect(!restored.usesSingletonWindows(bundleID: "us.zoom.xos"))
        #expect(LiveConfig(singletonExclude: ["us.zoom.xos"]).usesSingletonWindows(bundleID: "us.zoom.xos") == false)
    }

    @Test func directionalActionsRoundTripAndDispatchValidCommands() throws {
        for action in LiveConfig.SwipeDownAction.allCases {
            var config = LiveConfig.GestureConfig(
                swipeDown: action, swipeDownRight: action, swipeDownLeft: action,
                swipeDownApp: "com.apple.Terminal",
                swipeUpMode: .commands, swipeDownMode: .commands,
                swipeUp: action, swipeUpRight: action, swipeUpLeft: action)
            if action == .keystroke {
                for slot in LiveConfig.SwipeSlot.allCases { config.keystrokes[slot] = KeyStroke("ctrl-left") }
            }
            let data = try JSONEncoder().encode(config)
            #expect(try JSONDecoder().decode(LiveConfig.GestureConfig.self, from: data) == config)
            if let command = action.command {
                #expect(LiveCommand.validate(command) == nil)
                #expect(!["stop", "pause", "swipe"].contains(command[0]))
            }
        }
        let menu = LiveConfig.SwipeDownAction.groups.flatMap { $0.1 }
        #expect(Set(menu) == Set(LiveConfig.SwipeDownAction.allCases.filter { $0 != .none }))
        #expect(Set(menu).count == menu.count)
    }

    @Test func autoCenterConfiguration() throws {
        let defaults = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(defaults.autoCenter)
        #expect(defaults.autoCenterThreshold == 0.75)
        let custom = try JSONDecoder().decode(LiveConfig.self,
            from: Data(#"{"autoCenter":false,"autoCenterThreshold":0.6}"#.utf8))
        #expect(!custom.autoCenter)
        #expect(custom.autoCenterThreshold == 0.6)
        for value in ["0", "-0.1", "1.1"] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LiveConfig.self,
                    from: Data("{\"autoCenterThreshold\":\(value)}".utf8))
            }
        }
    }

    @Test func autoStackConfiguration() throws {
        let defaults = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(defaults.autoStack.isEmpty)
        let custom = try JSONDecoder().decode(LiveConfig.self,
            from: Data(#"{"autoStack":["com.apple.Terminal","com.mitchellh.ghostty"]}"#.utf8))
        #expect(custom.autoStacks(bundleID: "com.apple.Terminal"))
        #expect(!custom.autoStacks(bundleID: "com.apple.Safari"))
        #expect(!custom.autoStacks(bundleID: nil))
        let round = try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(custom))
        #expect(round.autoStack == custom.autoStack)
        let template = try JSONDecoder().decode(LiveConfig.self, from: Data(LiveConfig.template.utf8))
        #expect(template.autoStack.isEmpty)
    }

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
        let window = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"swipeDownLeft":"openAppWindow","swipeDownApp":"com.apple.Terminal"}}"#.utf8))
        #expect(window.gesture.swipeDownLeft == .openAppWindow)
        #expect(window.gesture.swipeDownLeft.title == "Open New Application Window")
        #expect(try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config)
        for json in [
            #"{"gesture":{"swipeDown":"openApp"}}"#,
            #"{"gesture":{"swipeDownRight":"openApp"}}"#,
            #"{"gesture":{"swipeUpLeft":"openAppWindow"}}"#,
            #"{"gesture":{"swipeDown":"openApp","swipeDownApp":" "}}"#
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            }
        }
    }

    @Test func keystrokeGesture() throws {
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(
            #"{"gesture":{"swipeUpMode":"commands","swipeUpLeft":"keystroke","swipeUpLeftKeystroke":"Cmd+Shift+LeftBracket","swipeDownKeystroke":"escape"}}"#.utf8))
        #expect(config.gesture.swipeUpLeft == .keystroke)
        #expect(config.gesture.action(.swipeUpLeft) == .keystroke)
        let stroke = try #require(config.gesture.keystrokes[.swipeUpLeft])
        #expect(stroke.spec == "shift-cmd-leftbracket")
        #expect(stroke.command && stroke.shift && !stroke.option && !stroke.control)
        // A keystroke may be configured for a slot not (yet) assigned to it; bare keys are allowed.
        #expect(config.gesture.keystrokes[.swipeDown]?.spec == "escape")
        #expect(LiveConfig.SwipeDownAction.keystroke.command == nil)
        #expect(try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config)
        for json in [
            #"{"gesture":{"swipeDownRight":"keystroke"}}"#,
            #"{"gesture":{"swipeUp":"keystroke","swipeUpKeystroke":"cmd-nosuchkey"}}"#,
            #"{"gesture":{"swipeDownKeystroke":"hyper-left"}}"#
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            }
        }
    }

    @Test func commandSwipes() throws {
        let defaults = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(!defaults.gesture.commandSwipesEnabled)
        #expect(LiveConfig.SwipeSlot.commandSwipes.allSatisfy { defaults.gesture.action($0) == .none })
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(
            #"{"gesture":{"cmdSwipeLeft":"swapLeft","cmdSwipeUp":"keystroke","cmdSwipeUpKeystroke":"ctrl-up","cmdSwipeDown":"openApp","swipeDownApp":"com.apple.Terminal"}}"#.utf8))
        #expect(config.gesture.commandSwipesEnabled)
        #expect(config.gesture.action(.cmdSwipeLeft) == .swapLeft)
        #expect(config.gesture.action(.cmdSwipeRight) == .none)
        #expect(config.gesture.keystrokes[.cmdSwipeUp]?.spec == "ctrl-up")
        #expect(try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config)) == config)
        for json in [
            #"{"gesture":{"cmdSwipeRight":"keystroke"}}"#,
            #"{"gesture":{"cmdSwipeDown":"openAppWindow"}}"#,
            #"{"gesture":{"cmdSwipeLeft":"teleport"}}"#
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
            }
        }
    }

    @Test func gapResizeDefaultsOn() throws {
        #expect(LiveConfig().gapResize)
        #expect(try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8)).gapResize)
        #expect(try !JSONDecoder().decode(LiveConfig.self, from: Data("{\"gapResize\":false}".utf8)).gapResize)
        #expect(try JSONDecoder().decode(LiveConfig.self, from: Data(LiveConfig.template.utf8)).gapResize)
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
        #expect(off.gesture.swipeUpMode == .commands)
        #expect(off.gesture.swipeUp == .none)
        #expect(!off.gesture.swipeUpToClose)
        #expect(off.gesture.tabCloseApps.isEmpty)
        let chrome = try JSONDecoder().decode(LiveConfig.self, from: Data(#"{"gesture":{"tabCloseApps":["com.google.Chrome"]}}"#.utf8))
        #expect(chrome.gesture.tabCloseApps == ["com.google.Chrome"])
        #expect(chrome.gesture.swipeUpToClose)
        #expect(chrome.gesture.swipeDown == .newWindow)
        #expect(chrome.gesture.swipeDownRight == .splitRight)
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
