import Carbon.HIToolbox
import Foundation
import Testing
@testable import PaperiPlatform

struct HotKeyBindingsTests {
    /// Mirrors ~/.hammerspoon/init.lua: every default binding is Option–Command.
    @Test func defaultsMatchUserPaperWMConfiguration() {
        let defaults = HotKeyBindings.defaults
        let table = Dictionary(uniqueKeysWithValues: defaults.map { ($0.spec, $0.command) })
        #expect(defaults.count == 16)
        #expect(defaults.allSatisfy { $0.modifiers == UInt32(cmdKey | optionKey) })
        #expect(Set(defaults.map(\.keyCode)).count == 16)
        #expect(table["alt-cmd-j"] == ["focus", "left"] && table["alt-cmd-k"] == ["focus", "right"])
        #expect(table["alt-cmd-f"] == ["float"] && table["alt-cmd-c"] == ["center"] && table["alt-cmd-s"] == ["split"])
        #expect(table["alt-cmd-left"] == ["swap", "left"] && table["alt-cmd-right"] == ["swap", "right"])
        #expect(table["alt-cmd-up"] == ["swap", "up"] && table["alt-cmd-down"] == ["swap", "down"])
        #expect(table["alt-cmd-l"] == ["width", "+"] && table["alt-cmd-h"] == ["width", "-"])
        #expect(table["alt-cmd-u"] == ["height", "+"] && table["alt-cmd-n"] == ["height", "-"])
        #expect(table["alt-cmd-i"] == ["slurp"] && table["alt-cmd-o"] == ["barf"])
        #expect(table["alt-cmd-t"] == ["tray"])
        for n in 1...9 { #expect(table["alt-cmd-\(n)"] == nil) }
        #expect(defaults.first { $0.spec == "alt-cmd-left" }?.display == "⌥⌘←")
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
        #expect(resolved.bindings.count == 16)
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
