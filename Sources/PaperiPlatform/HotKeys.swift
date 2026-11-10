import Carbon.HIToolbox
import Foundation

/// Global Option–Command bindings copied from the user's Hammerspoon/PaperWM
/// configuration (`~/.hammerspoon/init.lua`). Each binding dispatches the same
/// command vector as `paperi msg`, so CLI and keyboard behaviour cannot drift.
public enum HotKeyBindings {
    public struct Binding: Equatable, Sendable {
        /// Normalised spec, e.g. "alt-cmd-j"; also the config key.
        public let spec: String
        public let keyCode: UInt32
        public let modifiers: UInt32
        public let command: [String]
        public var display: String { HotKeySpec.display(spec) }
    }

    /// Defaults copied from the user's PaperWM configuration.
    public static let defaultTable: [(String, String)] = [
        ("alt-cmd-j", "focus left"), ("alt-cmd-k", "focus right"), ("alt-cmd-f", "float"),
        ("alt-cmd-left", "swap left"), ("alt-cmd-right", "swap right"),
        ("alt-cmd-up", "swap up"), ("alt-cmd-down", "swap down"),
        ("alt-cmd-c", "center"), ("alt-cmd-s", "split"),
        ("alt-cmd-l", "width +"), ("alt-cmd-h", "width -"),
        ("alt-cmd-u", "height +"), ("alt-cmd-n", "height -"),
        ("alt-cmd-i", "slurp"), ("alt-cmd-o", "barf"),
    ] + (1...9).map { ("alt-cmd-\($0)", "space \($0)") }

    public static var defaults: [Binding] { resolve(overrides: [:]).bindings }

    /// Merges config overrides over the defaults. A `nil` value removes a
    /// binding. Invalid key specs or commands are reported, never guessed.
    public static func resolve(overrides: [String: String?]) -> (bindings: [Binding], errors: [String]) {
        var table: [String: [String]] = [:]
        var order: [String] = []
        var errors: [String] = []
        func put(_ spec: String, _ command: String?, source: String) {
            guard let parsed = HotKeySpec.parse(spec) else { errors.append("\(source): unknown key \"\(spec)\""); return }
            let key = parsed.spec
            guard let command else { table.removeValue(forKey: key); return }
            let args = command.split(separator: " ").map(String.init)
            if let problem = LiveCommand.validate(args) { errors.append("\(source) \"\(spec)\": \(problem)"); return }
            if table[key] == nil { order.append(key) }
            table[key] = args
        }
        for (spec, command) in defaultTable { put(spec, command, source: "default") }
        for spec in overrides.keys.sorted() { put(spec, overrides[spec]!, source: "hotkeys") }
        let bindings = order.compactMap { spec -> Binding? in
            guard let command = table[spec], let parsed = HotKeySpec.parse(spec) else { return nil }
            return Binding(spec: spec, keyCode: parsed.keyCode, modifiers: parsed.modifiers, command: command)
        }
        return (bindings, errors)
    }
}

/// Parses "alt-cmd-j" / "ctrl+shift+left" style key specs.
public enum HotKeySpec {
    static let modifierNames: [String: (bit: Int, canonical: String)] = [
        "cmd": (cmdKey, "cmd"), "command": (cmdKey, "cmd"),
        "alt": (optionKey, "alt"), "opt": (optionKey, "alt"), "option": (optionKey, "alt"),
        "ctrl": (controlKey, "ctrl"), "control": (controlKey, "ctrl"),
        "shift": (shiftKey, "shift"),
    ]
    static let canonicalOrder = ["ctrl", "alt", "shift", "cmd"]
    static let symbols: [String: String] = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]

    static let keys: [String: Int] = {
        var k: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
            "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
            "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash, "semicolon": kVK_ANSI_Semicolon,
            "quote": kVK_ANSI_Quote, "grave": kVK_ANSI_Grave,
            "leftbracket": kVK_ANSI_LeftBracket, "rightbracket": kVK_ANSI_RightBracket,
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fkeys.enumerated() { k["f\(i + 1)"] = code }
        return k
    }()

    /// Requires at least one modifier so a typo cannot swallow plain typing.
    public static func parse(_ raw: String) -> (spec: String, keyCode: UInt32, modifiers: UInt32)? {
        let parts = raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "+" }).map(String.init)
        guard parts.count >= 2, let key = parts.last, let code = keys[key] else { return nil }
        var bits = 0
        var names: Set<String> = []
        for part in parts.dropLast() {
            guard let m = modifierNames[part] else { return nil }
            bits |= m.bit; names.insert(m.canonical)
        }
        let spec = (canonicalOrder.filter(names.contains) + [key]).joined(separator: "-")
        return (spec, UInt32(code), UInt32(bits))
    }

    static func display(_ spec: String) -> String {
        let parts = spec.split(separator: "-").map(String.init)
        guard let key = parts.last else { return spec }
        let arrows = ["left": "←", "right": "→", "up": "↑", "down": "↓"]
        return parts.dropLast().compactMap { symbols[$0] }.joined() + (arrows[key] ?? key.uppercased())
    }
}

/// Shared validation for CLI, socket and hot-key commands.
public enum LiveCommand {
    static let directions: Set<String> = ["left", "right", "up", "down"]
    /// Returns a problem description, or nil when the command is valid.
    public static func validate(_ args: [String]) -> String? {
        guard let verb = args.first else { return "empty command" }
        let rest = Array(args.dropFirst())
        switch verb {
        case "status", "retile", "refresh", "stop", "center", "split", "slurp", "barf", "float", "pause", "resume", "reload":
            return rest.isEmpty ? nil : "\(verb) takes no arguments"
        case "focus", "swap", "move":
            return rest.count == 1 && directions.contains(rest[0]) ? nil : "usage: \(verb) left|right|up|down"
        case "width", "height":
            guard (1...2).contains(rest.count), rest[0] == "+" || rest[0] == "-" else { return "usage: \(verb) +|- [fraction]" }
            if rest.count == 2 { guard let f = Double(rest[1]), f > 0, f <= 1 else { return "fraction must be in (0, 1]" } }
            return nil
        case "space":
            return rest.count == 1 && Int(rest[0]).map { $0 >= 1 } == true ? nil : "usage: space N"
        default:
            return "unknown command \(verb)"
        }
    }
}

/// Carbon hot-key registration. Registration needs no Accessibility or Input
/// Monitoring permission and never observes other keystrokes. A combination
/// already held by another process (e.g. Hammerspoon) fails individually and
/// is reported rather than silently shadowed.
@MainActor public final class HotKeyCenter {
    private static var current: HotKeyCenter?
    private var refs: [EventHotKeyRef] = []
    private var commands: [UInt32: [String]] = [:]
    private var handler: EventHandlerRef?
    private let dispatch: @MainActor ([String]) -> Void

    public init(dispatch: @escaping @MainActor ([String]) -> Void) { self.dispatch = dispatch }

    /// Returns the keys that could not be registered with their OSStatus.
    @discardableResult
    public func register(_ bindings: [HotKeyBindings.Binding] = HotKeyBindings.defaults) -> [String: Int32] {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll(); commands.removeAll()
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return noErr }
                let identifier = id.id
                // Carbon delivers hot keys on the main thread; defer so the
                // command never runs inside the Carbon dispatch callback.
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.current?.fire(identifier) } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        var failures: [String: Int32] = [:]
        for (index, binding) in bindings.enumerated() {
            let identifier = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                             EventHotKeyID(signature: OSType(0x5041_5052), id: identifier), // 'PAPR'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref); commands[identifier] = binding.command }
            else { failures[binding.display] = status }
        }
        return failures
    }

    public var registeredCount: Int { refs.count }

    private func fire(_ identifier: UInt32) {
        guard let command = commands[identifier] else { return }
        dispatch(command)
    }

    public func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll(); commands.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        if Self.current === self { Self.current = nil }
    }
}
