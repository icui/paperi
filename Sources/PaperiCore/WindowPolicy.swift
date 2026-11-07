import Foundation

public struct WindowFacts: Codable, Equatable, Sendable {
    public var bundleID: String
    public var role: String?
    public var subrole: String?
    public var isRoot: Bool?
    public var movable: Bool?
    public var resizable: Bool?
    public var fullscreen: Bool?
    public var minimized: Bool?
    public var level: Int?

    public init(bundleID: String, role: String? = nil, subrole: String? = nil,
                isRoot: Bool? = nil, movable: Bool? = nil, resizable: Bool? = nil,
                fullscreen: Bool? = false, minimized: Bool? = false, level: Int? = nil) {
        self.bundleID = bundleID; self.role = role; self.subrole = subrole
        self.isRoot = isRoot; self.movable = movable; self.resizable = resizable
        self.fullscreen = fullscreen; self.minimized = minimized; self.level = level
    }
}

public enum Eligibility: String, Codable, Sendable { case tiled, floating, excluded, pending }
public struct Classification: Codable, Equatable, Sendable {
    public var eligibility: Eligibility
    public var reason: String
}

public enum WindowPolicy {
    public static func classify(_ facts: WindowFacts, userFloating: Bool = false) -> Classification {
        func result(_ eligibility: Eligibility, _ reason: String) -> Classification {
            Classification(eligibility: eligibility, reason: reason)
        }
        let systemOwners = ["com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.dock", "com.apple.systemuiserver"]
        if systemOwners.contains(facts.bundleID.lowercased()) { return result(.excluded, "system overlay owner") }
        if facts.fullscreen == true || facts.minimized == true { return result(.excluded, "fullscreen or minimized") }
        guard let role = facts.role else { return result(.pending, "missing role metadata") }
        guard role == "AXWindow" else { return result(.excluded, "non-window role") }
        guard let subrole = facts.subrole else { return result(.pending, "missing subrole metadata") }
        guard subrole == "AXStandardWindow" else { return result(.excluded, "transient or nonstandard role") }
        guard let root = facts.isRoot else { return result(.pending, "missing parent metadata") }
        guard root else { return result(.excluded, "child window") }
        guard let level = facts.level else { return result(.pending, "missing window level") }
        guard level == 0 else { return result(.excluded, "non-normal window level") }
        guard facts.fullscreen != nil, facts.minimized != nil else { return result(.pending, "missing presentation metadata") }
        guard let movable = facts.movable, let resizable = facts.resizable else { return result(.pending, "missing capability metadata") }
        guard movable && resizable else { return result(.excluded, "not a movable resizable document") }
        return result(userFloating ? .floating : .tiled, userFloating ? "user floating" : "eligible document")
    }
}
