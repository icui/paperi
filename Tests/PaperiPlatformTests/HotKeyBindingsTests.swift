import Carbon.HIToolbox
import Testing
@testable import PaperiPlatform

struct HotKeyBindingsTests {
    /// Mirrors ~/.hammerspoon/init.lua: every binding is Option–Command.
    @Test func bindingsMatchUserPaperWMConfiguration() {
        let table = Dictionary(uniqueKeysWithValues: HotKeyBindings.defaults.map { ($0.key, $0.command) })
        #expect(HotKeyBindings.modifiers == UInt32(cmdKey | optionKey))
        #expect(HotKeyBindings.defaults.count == 24)
        #expect(Set(HotKeyBindings.defaults.map(\.keyCode)).count == 24)
        #expect(table["J"] == ["focus", "left"] && table["K"] == ["focus", "right"])
        #expect(table["F"] == ["float"] && table["C"] == ["center"] && table["S"] == ["split"])
        #expect(table["←"] == ["swap", "left"] && table["→"] == ["swap", "right"])
        #expect(table["↑"] == ["swap", "up"] && table["↓"] == ["swap", "down"])
        #expect(table["L"] == ["width", "+"] && table["H"] == ["width", "-"])
        #expect(table["U"] == ["height", "+"] && table["N"] == ["height", "-"])
        #expect(table["I"] == ["slurp"] && table["O"] == ["barf"])
        for n in 1...9 { #expect(table["\(n)"] == ["space", "\(n)"]) }
    }
}
