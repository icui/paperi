import Foundation
import PaperiCore

/// Live-mode configuration, read from
/// `~/Library/Application Support/Paperi/config.json` when present.
///
/// By default every regular (Dock-visible) application is considered. Which
/// *windows* are tiled is still decided per window by `WindowPolicy`
/// (standard, root, normal level, movable and resizable; popups, sheets,
/// dialogs, panels and menus are never tiled). This file only names apps to
/// skip, apps without native tabs, and windows that should stay floating.
public struct LiveConfig: Codable, Equatable, Sendable {
    public struct FloatRule: Codable, Equatable, Sendable {
        public var app: String
        /// Optional case-insensitive substring of the window title.
        public var titleContains: String?
        public init(app: String, titleContains: String? = nil) { self.app = app; self.titleContains = titleContains }
    }

    public struct GestureConfig: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var fingers: Int
        public var travel: Double
        public var commitThreshold: Double
        public var flickVelocity: Double
        public var invert: Bool
        /// Swiping up closes the focused window (its front tab in a native
        /// tab group).
        public var swipeUpToClose: Bool
        /// Bundle IDs whose windows hold in-content tabs (e.g. Chrome): a
        /// swipe up closes the current tab with ⌘W instead of the window.
        public var tabCloseApps: [String]
        /// What swiping down does to the focused window.
        public var swipeDownApp: String?
        public var swipeDown: SwipeDownAction
        public var swipeDownRight: SwipeDownAction
        public var swipeDownLeft: SwipeDownAction
        /// What a quick tap with all `fingers` does.
        public var tap: TapAction

        public init(enabled: Bool = true, fingers: Int = 3, travel: Double = 0.4,
                    commitThreshold: Double = 0.5, flickVelocity: Double = 1.5, invert: Bool = false,
                    swipeUpToClose: Bool = true, tabCloseApps: [String] = [], swipeDown: SwipeDownAction = .newWindow,
                    swipeDownRight: SwipeDownAction = .closeTab, swipeDownLeft: SwipeDownAction = .minimize, swipeDownApp: String? = nil,
                    tap: TapAction = .tray) {
            self.enabled = enabled
            self.fingers = fingers
            self.travel = travel
            self.commitThreshold = commitThreshold
            self.flickVelocity = flickVelocity
            self.invert = invert
            self.swipeUpToClose = swipeUpToClose
            self.tabCloseApps = tabCloseApps
            self.swipeDownApp = swipeDownApp
            self.swipeDown = swipeDown
            self.swipeDownRight = swipeDownRight
            self.swipeDownLeft = swipeDownLeft
            self.tap = tap
        }

        enum CodingKeys: String, CodingKey {
            case swipeDownApp
            case enabled, fingers, travel, commitThreshold, flickVelocity, invert, swipeUpToClose, tabCloseApps, swipeDown, swipeDownRight, swipeDownLeft, tap
            /// Legacy boolean: `false` reads as `swipeDown: "none"`.
            case swipeDownToMinimize
        }

        /// Omitted keys keep their defaults.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = GestureConfig()
            swipeDownApp = try c.decodeIfPresent(String.self, forKey: .swipeDownApp)
            if let app = swipeDownApp, app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw DecodingError.dataCorruptedError(forKey: .swipeDownApp, in: c, debugDescription: "expected an app bundle ID")
            }
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
            fingers = try c.decodeIfPresent(Int.self, forKey: .fingers) ?? d.fingers
            travel = try c.decodeIfPresent(Double.self, forKey: .travel) ?? d.travel
            commitThreshold = try c.decodeIfPresent(Double.self, forKey: .commitThreshold) ?? d.commitThreshold
            flickVelocity = try c.decodeIfPresent(Double.self, forKey: .flickVelocity) ?? d.flickVelocity
            invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? d.invert
            swipeUpToClose = try c.decodeIfPresent(Bool.self, forKey: .swipeUpToClose) ?? d.swipeUpToClose
            tabCloseApps = try c.decodeIfPresent([String].self, forKey: .tabCloseApps) ?? d.tabCloseApps
            swipeDownRight = try c.decodeIfPresent(SwipeDownAction.self, forKey: .swipeDownRight) ?? d.swipeDownRight
            swipeDownLeft = try c.decodeIfPresent(SwipeDownAction.self, forKey: .swipeDownLeft) ?? d.swipeDownLeft
            tap = try c.decodeIfPresent(TapAction.self, forKey: .tap) ?? d.tap
            if let raw = try c.decodeIfPresent(String.self, forKey: .swipeDown) {
                guard let action = SwipeDownAction(rawValue: raw) else {
                    throw DecodingError.dataCorruptedError(forKey: .swipeDown, in: c,
                        debugDescription: "expected closeTab, minimize, newWindow, openApp or none, got \(raw)")
                }
                swipeDown = action
            } else if try c.decodeIfPresent(Bool.self, forKey: .swipeDownToMinimize) == false {
                swipeDown = .none
            } else {
                swipeDown = d.swipeDown
            }
            if [swipeDown, swipeDownRight, swipeDownLeft].contains(.openApp), swipeDownApp == nil {
                throw DecodingError.dataCorruptedError(forKey: .swipeDownApp, in: c, debugDescription: "openApp requires swipeDownApp (an app bundle ID)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled); try c.encode(fingers, forKey: .fingers)
            try c.encode(travel, forKey: .travel); try c.encode(commitThreshold, forKey: .commitThreshold)
            try c.encode(flickVelocity, forKey: .flickVelocity); try c.encode(invert, forKey: .invert)
            try c.encode(swipeUpToClose, forKey: .swipeUpToClose); try c.encode(tabCloseApps, forKey: .tabCloseApps)
            try c.encodeIfPresent(swipeDownApp, forKey: .swipeDownApp)
            try c.encode(swipeDown.rawValue, forKey: .swipeDown)
            try c.encode(swipeDownRight, forKey: .swipeDownRight)
            try c.encode(swipeDownLeft, forKey: .swipeDownLeft)
            try c.encode(tap, forKey: .tap)
        }
    }

    /// Actions shared by the three downward gestures. New window uses the
    /// app's New Window menu item, falling back to ⌘N.
    public enum SwipeDownAction: String, Codable, Equatable, Sendable, CaseIterable { case closeTab, minimize, newWindow, openApp, none }

    /// A gesture-finger tap shows the thumbnail tray centred on the pointer
    /// (`tray`), or does nothing (`none`).
    public enum TapAction: String, Codable, Equatable, Sendable, CaseIterable { case tray, none }

    /// Where focus goes when the focused tiled window closes: the column to
    /// the `left` (else right), to the `right` (else left), or wherever macOS
    /// puts it (`system`). A surviving tab or stacked window keeps the column.
    public enum FocusAfterClose: String, Codable, Equatable, Sendable, CaseIterable { case left, right, system }

    /// When set, only these bundle IDs are managed (the `--app` flag).
    public var include: [String]?
    /// Bundle IDs never managed, in addition to `defaultExclude`.
    public var exclude: [String]
    /// Apps without native macOS tabs whose tab bars are drawn in-content.
    public var singleton: [String]
    /// Windows that stay floating (not tiled) while still managed for focus.
    public var float: [FloatRule]
    /// Windows tiled even though they look like utility windows (no
    /// fullscreen button), e.g. System Settings.
    public var tile: [FloatRule]
    /// Focus-scroll duration in seconds; zero disables animation.
    public var focusScrollDuration: Double?
    public var focusAfterClose: FocusAfterClose
    public var gap: Double?
    /// Indicator along the bottom of each display. The thumbnail tray is
    /// summoned on demand instead (tap or the `tray` command); the retired
    /// `thumbnail` value reads as `dot`.
    public enum Bottom: String, Codable, CaseIterable, Sendable {
        case none, dot
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            if raw == "thumbnail" { self = .dot; return }
            guard let value = Bottom(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected none or dot, got \(raw)")
            }
            self = value
        }
    }
    public var bottom: Bottom = .dot
    public var outerGap: Double?
    /// Key spec → command (as accepted by `paperi msg`), merged over the
    /// built-in PaperWM bindings; `null` removes a default binding.
    public var hotkeys: [String: String?]
    /// Mask over the column a dragged window would swap with, `#RRGGBB[AA]`.
    public var swapHighlight: String?
    /// Legacy color setting, retained for config compatibility; no longer displayed.
    public var edgeHint: String?
    public static let defaultEdgeHint = "#0A84FF"
    public var edgeHintColor: HexColor { edgeHint.flatMap(HexColor.init) ?? HexColor(Self.defaultEdgeHint)! }
    public static let defaultSwapHighlight = "#0A84FF4D"
    public var swapHighlightColor: HexColor { swapHighlight.flatMap(HexColor.init) ?? HexColor(Self.defaultSwapHighlight)! }
    /// Trackpad swipe gesture configuration.
    public var gesture: GestureConfig

    public init(include: [String]? = nil, exclude: [String] = [], singleton: [String] = [],
                float: [FloatRule] = [], tile: [FloatRule] = [], gap: Double? = nil, outerGap: Double? = nil,
                gesture: GestureConfig? = nil) {
        self.include = include; self.exclude = exclude; self.singleton = singleton
        self.float = float; self.tile = tile; self.gap = gap; self.outerGap = outerGap
        self.hotkeys = [:]
        self.focusAfterClose = .left
        self.gesture = gesture ?? GestureConfig()
    }

    enum CodingKeys: String, CodingKey {
        case bottom, include, exclude, singleton, float, tile, gap, outerGap, hotkeys, swapHighlight, edgeHint, focusScrollDuration, focusAfterClose, gesture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        include = try c.decodeIfPresent([String].self, forKey: .include)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        singleton = try c.decodeIfPresent([String].self, forKey: .singleton) ?? []
        float = try c.decodeIfPresent([FloatRule].self, forKey: .float) ?? []
        tile = try c.decodeIfPresent([FloatRule].self, forKey: .tile) ?? []
        focusScrollDuration = try c.decodeIfPresent(Double.self, forKey: .focusScrollDuration)
        if let duration = focusScrollDuration, !duration.isFinite || duration < 0 || duration > 1 {
            throw DecodingError.dataCorruptedError(forKey: .focusScrollDuration, in: c, debugDescription: "expected seconds from 0 to 1")
        }
        if let raw = try c.decodeIfPresent(String.self, forKey: .focusAfterClose) {
            guard let value = FocusAfterClose(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .focusAfterClose, in: c,
                    debugDescription: "expected left, right or system, got \(raw)")
            }
            focusAfterClose = value
        } else {
            focusAfterClose = .left
        }
        bottom = try c.decodeIfPresent(Bottom.self, forKey: .bottom) ?? .dot
        gap = try c.decodeIfPresent(Double.self, forKey: .gap)
        outerGap = try c.decodeIfPresent(Double.self, forKey: .outerGap)
        hotkeys = try c.decodeIfPresent([String: String?].self, forKey: .hotkeys) ?? [:]
        edgeHint = try c.decodeIfPresent(String.self, forKey: .edgeHint)
        if let edgeHint, HexColor(edgeHint) == nil {
            throw DecodingError.dataCorruptedError(forKey: .edgeHint, in: c,
                debugDescription: "expected #RRGGBB or #RRGGBBAA, got \(edgeHint)")
        }
        swapHighlight = try c.decodeIfPresent(String.self, forKey: .swapHighlight)
        if let swapHighlight, HexColor(swapHighlight) == nil {
            throw DecodingError.dataCorruptedError(forKey: .swapHighlight, in: c,
                debugDescription: "expected #RRGGBB or #RRGGBBAA, got \(swapHighlight)")
        }
        if let g = try c.decodeIfPresent(GestureConfig.self, forKey: .gesture) {
            if g.fingers != 3 && g.fingers != 4 {
                throw DecodingError.dataCorruptedError(forKey: .gesture, in: c, debugDescription: "expected 3 or 4 fingers")
            }
            if !g.travel.isFinite || g.travel <= 0 || g.travel > 1 {
                throw DecodingError.dataCorruptedError(forKey: .gesture, in: c, debugDescription: "expected travel in (0, 1]")
            }
            if !g.commitThreshold.isFinite || g.commitThreshold <= 0 || g.commitThreshold > 1 {
                throw DecodingError.dataCorruptedError(forKey: .gesture, in: c, debugDescription: "expected commitThreshold in (0, 1]")
            }
            if !g.flickVelocity.isFinite || g.flickVelocity <= 0 {
                throw DecodingError.dataCorruptedError(forKey: .gesture, in: c, debugDescription: "expected positive flickVelocity")
            }
            gesture = g
        } else {
            gesture = GestureConfig()
        }
    }

    /// System UI and agents whose windows must never be tiled, plus Paperi.
    public static let defaultExclude: Set<String> = [
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.Spotlight", "com.apple.WindowManager", "com.apple.screencaptureui", "com.apple.PIPAgent",
        "com.apple.loginwindow", "com.apple.UserNotificationCenter", "com.apple.CoreServicesUIAgent",
        "com.apple.SecurityAgent", "com.apple.universalcontrol", "com.apple.TextInputMenuAgent",
        "dev.paperi.app",
    ]

    /// Starter file written by the menu's "Open Config…" when none exists.
    public static let template = """
    {
      "exclude": [],
      "float": [],
      "tile": [],
      "singleton": [],
      "focusScrollDuration": 0.22,
      "focusAfterClose": "left",
      "gap": 8,
      "outerGap": 8,
      "bottom": "dot",
      "swapHighlight": "#0A84FF4D",
      "gesture": {
        "enabled": true,
        "fingers": 3,
        "travel": 0.4,
        "commitThreshold": 0.5,
        "flickVelocity": 1.5,
        "invert": false,
        "swipeUpToClose": true,
        "tabCloseApps": [],
        "swipeDown": "newWindow",
        "swipeDownRight": "closeTab",
        "swipeDownLeft": "minimize",
        "tap": "tray"
      },
      "hotkeys": {
        "alt-cmd-j": "focus left",
        "alt-cmd-k": "focus right"
      }
    }

    """

    public static var defaultURL: URL { LiveManager.supportDirectory.appendingPathComponent("config.json") }

    public static func load(from url: URL = defaultURL) throws -> LiveConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return LiveConfig() }
        return try JSONDecoder().decode(LiveConfig.self, from: Data(contentsOf: url))
    }

    /// `regular` is `NSApplication.ActivationPolicy.regular`: accessory/agent
    /// apps are only managed when explicitly included.
    public func manages(bundleID: String?, regular: Bool) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if Self.defaultExclude.contains(bundleID) || exclude.contains(bundleID) { return false }
        if let include { return include.contains(bundleID) }
        return regular
    }

    public func floats(bundleID: String, title: String?) -> Bool { Self.matches(float, bundleID, title) }
    public func tiles(bundleID: String, title: String?) -> Bool { Self.matches(tile, bundleID, title) }

    private static func matches(_ rules: [FloatRule], _ bundleID: String, _ title: String?) -> Bool {
        rules.contains { rule in
            guard rule.app == bundleID else { return false }
            guard let needle = rule.titleContains, !needle.isEmpty else { return true }
            return title?.localizedCaseInsensitiveContains(needle) == true
        }
    }
}
