import Foundation

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
    public var gap: Double?
    public var outerGap: Double?
    /// Key spec → command (as accepted by `paperi msg`), merged over the
    /// built-in PaperWM bindings; `null` removes a default binding.
    public var hotkeys: [String: String?]

    public init(include: [String]? = nil, exclude: [String] = [], singleton: [String] = [],
                float: [FloatRule] = [], tile: [FloatRule] = [], gap: Double? = nil, outerGap: Double? = nil) {
        self.include = include; self.exclude = exclude; self.singleton = singleton
        self.float = float; self.tile = tile; self.gap = gap; self.outerGap = outerGap
        self.hotkeys = [:]
    }

    enum CodingKeys: String, CodingKey { case include, exclude, singleton, float, tile, gap, outerGap, hotkeys }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        include = try c.decodeIfPresent([String].self, forKey: .include)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        singleton = try c.decodeIfPresent([String].self, forKey: .singleton) ?? []
        float = try c.decodeIfPresent([FloatRule].self, forKey: .float) ?? []
        tile = try c.decodeIfPresent([FloatRule].self, forKey: .tile) ?? []
        gap = try c.decodeIfPresent(Double.self, forKey: .gap)
        outerGap = try c.decodeIfPresent(Double.self, forKey: .outerGap)
        hotkeys = try c.decodeIfPresent([String: String?].self, forKey: .hotkeys) ?? [:]
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
      "gap": 8,
      "outerGap": 8,
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
