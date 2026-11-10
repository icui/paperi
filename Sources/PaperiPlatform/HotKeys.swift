import Carbon.HIToolbox
import Foundation

/// Global Option–Command bindings copied from the user's Hammerspoon/PaperWM
/// configuration (`~/.hammerspoon/init.lua`). Each binding dispatches the same
/// command vector as `paperi msg`, so CLI and keyboard behaviour cannot drift.
public enum HotKeyBindings {
    public struct Binding: Sendable {
        public let key: String
        public let keyCode: UInt32
        public let command: [String]
    }

    public static let modifiers = UInt32(cmdKey | optionKey)

    public static let defaults: [Binding] = {
        var rows: [Binding] = [
            .init(key: "J", keyCode: UInt32(kVK_ANSI_J), command: ["focus", "left"]),
            .init(key: "K", keyCode: UInt32(kVK_ANSI_K), command: ["focus", "right"]),
            .init(key: "F", keyCode: UInt32(kVK_ANSI_F), command: ["float"]),
            .init(key: "←", keyCode: UInt32(kVK_LeftArrow), command: ["swap", "left"]),
            .init(key: "→", keyCode: UInt32(kVK_RightArrow), command: ["swap", "right"]),
            .init(key: "↑", keyCode: UInt32(kVK_UpArrow), command: ["swap", "up"]),
            .init(key: "↓", keyCode: UInt32(kVK_DownArrow), command: ["swap", "down"]),
            .init(key: "C", keyCode: UInt32(kVK_ANSI_C), command: ["center"]),
            .init(key: "S", keyCode: UInt32(kVK_ANSI_S), command: ["split"]),
            .init(key: "L", keyCode: UInt32(kVK_ANSI_L), command: ["width", "+"]),
            .init(key: "H", keyCode: UInt32(kVK_ANSI_H), command: ["width", "-"]),
            .init(key: "U", keyCode: UInt32(kVK_ANSI_U), command: ["height", "+"]),
            .init(key: "N", keyCode: UInt32(kVK_ANSI_N), command: ["height", "-"]),
            .init(key: "I", keyCode: UInt32(kVK_ANSI_I), command: ["slurp"]),
            .init(key: "O", keyCode: UInt32(kVK_ANSI_O), command: ["barf"]),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() {
            rows.append(.init(key: "\(i + 1)", keyCode: UInt32(code), command: ["space", "\(i + 1)"]))
        }
        return rows
    }()
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
            let status = RegisterEventHotKey(binding.keyCode, HotKeyBindings.modifiers,
                                             EventHotKeyID(signature: OSType(0x5041_5052), id: identifier), // 'PAPR'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref); commands[identifier] = binding.command }
            else { failures["⌥⌘\(binding.key)"] = status }
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
