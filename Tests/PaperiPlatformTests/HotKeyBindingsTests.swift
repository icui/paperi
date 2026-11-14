import Carbon.HIToolbox
import Foundation
import Testing
@testable import PaperiPlatform

struct HotKeyBindingsTests {
    @Test func defaultsUseArrowsForFocusAndShiftForSwap() {
        let defaults = HotKeyBindings.defaults
        let table = Dictionary(uniqueKeysWithValues: defaults.map { ($0.spec, $0.command) })
        #expect(defaults.count == 13)
        for direction in ["left", "right", "up", "down"] {
            #expect(table["alt-cmd-\(direction)"] == ["focus", direction])
            #expect(table["alt-shift-cmd-\(direction)"] == ["swap", direction])
        }
        for (key, _) in HotKeyBindings.advancedTable { #expect(table[key] == nil) }
        #expect(table["alt-cmd-j"] == nil && table["alt-cmd-k"] == nil)
        #expect(Set(defaults.map { "\($0.modifiers):\($0.keyCode)" }).count == defaults.count)
        #expect(LiveCommand.validate(["align", "left"]) == nil)
        #expect(LiveCommand.validate(["align", "right"]) == nil)
        #expect(LiveCommand.validate(["align", "center"]) == nil)
        #expect(LiveCommand.validate(["align", "up"]) != nil)
        #expect(LiveCommand.validate(["align"]) != nil)
    }

    @Test func specsNormaliseModifierOrderAndAliases() {
        #expect(HotKeySpec.parse("cmd-alt-j")?.spec == "alt-cmd-j")
        #expect(HotKeySpec.parse("Option+Command+J")?.spec == "alt-cmd-j")
        #expect(HotKeySpec.parse("shift-ctrl-f12")?.spec == "ctrl-shift-f12")
        #expect(HotKeySpec.parse("ctrl-alt-left")?.keyCode == UInt32(kVK_LeftArrow))
        #expect(HotKeySpec.parse("j") == nil)              // no modifier
        #expect(HotKeySpec.parse("hyper-j") == nil)        // unknown modifier
        #expect(HotKeySpec.parse("alt-cmd-banana") == nil) // unknown key
    }

    @Test func overridesMergeRemoveAndReportErrors() {
        let resolved = HotKeyBindings.resolve(overrides: [
            "cmd-alt-j": "focus up",          // replaces default (alias order)
            "alt-cmd-o": nil,                  // removes default
            "ctrl-alt-l": "width + 0.2",       // adds
            "ctrl-alt-x": "explode",           // invalid command
            "hyper-k": "focus right",          // invalid key
        ])
        let table = Dictionary(uniqueKeysWithValues: resolved.bindings.map { ($0.spec, $0.command) })
        #expect(table["alt-cmd-j"] == ["focus", "up"])
        #expect(table["alt-cmd-o"] == nil)
        #expect(table["ctrl-alt-l"] == ["width", "+", "0.2"])
        #expect(resolved.bindings.count == 15)
        #expect(resolved.errors.count == 2)
    }

    @Test func commandValidationMatchesCLI() {
        #expect(LiveCommand.validate(["focus", "left"]) == nil)
        #expect(LiveCommand.validate(["width", "+", "0.25"]) == nil)
        #expect(LiveCommand.validate(["pause"]) == nil)
        #expect(LiveCommand.validate(["focus", "sideways"]) != nil)
        #expect(LiveCommand.validate(["width", "+", "2"]) != nil)
        #expect(LiveCommand.validate(["space", "3"]) != nil)
        #expect(LiveCommand.validate([]) != nil)
    }

    @Test func globalShortcutToggleDefaultsAndRoundTrips() throws {
        let defaults = try JSONDecoder().decode(LiveConfig.self, from: Data("{}".utf8))
        #expect(defaults.hotkeysEnabled)
        let json = #"{"hotkeysEnabled":false,"hotkeys":{"ctrl-alt-j":"focus left"}}"#
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
        #expect(!config.hotkeysEnabled)
        #expect(config.hotkeys["ctrl-alt-j"] == .some("focus left"))
        let restored = try JSONDecoder().decode(LiveConfig.self, from: JSONEncoder().encode(config))
        #expect(restored == config)
    }

    @Test func configDecodesHotkeysWithNullRemoval() throws {
        let json = #"{"hotkeys":{"alt-cmd-1":null,"ctrl-alt-l":"width + 0.2"}}"#
        let config = try JSONDecoder().decode(LiveConfig.self, from: Data(json.utf8))
        #expect(config.hotkeys.count == 2)
        #expect(config.hotkeys["alt-cmd-1"] == .some(nil))
        #expect(config.hotkeys["ctrl-alt-l"] == .some("width + 0.2"))
        let template = try JSONDecoder().decode(LiveConfig.self, from: Data(LiveConfig.template.utf8))
        #expect(HotKeyBindings.resolve(overrides: template.hotkeys).errors.isEmpty)
    }
}
