import AppKit
import PaperiBridge

/// Runtime check of the private interfaces live mode cannot work without.
///
/// FRAGILE: Paperi reads Spaces through private SkyLight functions and window
/// IDs through `_AXUIElementGetWindow` (see PaperiBridge.c). A macOS update
/// can remove them, refuse them to ordinary apps, or change the undocumented
/// dictionary they return. Each of these would otherwise leave Paperi running
/// but managing nothing, with no visible error. This check turns them into a
/// pause with a stated reason, through the same path as unsupported display
/// arrangements (`DisplayArrangement.currentProblem`).
///
/// Not covered: `_AXUIElementGetWindow` resolving but returning 0 for real
/// windows, and `SLSCopySpacesForWindows` changing its answers. Both show up
/// as windows that are never managed (`paperi check-apps` explains each one).
public enum SkyLightHealth {
    public static let header = "Paperi can't read Space information from macOS"

    /// Whether a pause reason came from this check rather than display settings.
    public static func isProblem(_ text: String) -> Bool { text.hasPrefix(header) }

    /// Cached for `cacheSeconds`: callers include per-touch-frame swipe
    /// handling, and a full check costs about 1 ms (macOS 26.7.2, arm64).
    @MainActor public static func currentProblem() -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.at < cacheSeconds { return cached.problem }
        let problem = uncachedProblem()
        cached = (now, problem)
        return problem
    }

    static let cacheSeconds = 2.0
    @MainActor private static var cached: (at: Double, problem: String?)?

    @MainActor static func uncachedProblem() -> String? {
        let missing = (paperi_copy_missing_private_functions() as? [String]) ?? []
        let connection = missing.contains("SLSMainConnectionID") ? 0 : paperi_skylight_connection()
        let raw: Any? = connection == 0 ? nil : paperi_copy_display_spaces()
        return problem(missingFunctions: missing, connection: connection, displaySpaces: raw,
                       screenCount: NSScreen.screens.count, spaceType: { paperi_space_type($0) })
    }

    /// Returns a user-facing explanation, or nil if the data has the shape
    /// `DisplaySpaceCoordinator` relies on.
    static func problem(missingFunctions: [String], connection: Int32, displaySpaces: Any?,
                        screenCount: Int, spaceType: (UInt64) -> Int32) -> String? {
        func explain(_ detail: String) -> String {
            "\(header) (\(detail)). A macOS update may have changed a private interface Paperi depends on. "
                + "Windows are left where they are, and Paperi resumes on its own if this clears. "
                + "See “Private macOS interfaces” in the README."
        }
        if !missingFunctions.isEmpty {
            return explain("missing private functions: \(missingFunctions.joined(separator: ", "))")
        }
        if connection == 0 { return explain("SLSMainConnectionID returned 0") }
        guard screenCount > 0 else { return nil }
        guard let raw = displaySpaces else { return explain("SLSCopyManagedDisplaySpaces returned nothing") }
        guard let entries = raw as? [[String: Any]] else {
            return explain("SLSCopyManagedDisplaySpaces returned an unexpected \(type(of: raw))")
        }
        if entries.isEmpty {
            return explain("SLSCopyManagedDisplaySpaces lists no displays although \(screenCount) are connected")
        }
        var types: [Int32] = []
        for (index, entry) in entries.enumerated() {
            guard entry["Display Identifier"] is String else {
                return explain("display entry \(index) has no “Display Identifier”; keys: \(entry.keys.sorted().joined(separator: ", "))")
            }
            let ids = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            guard !ids.isEmpty else {
                return explain("display entry \(index) lists no Spaces with a “ManagedSpaceID”")
            }
            types += ids.map(spaceType)
        }
        // Every display has at least one normal desktop; SkyLight reports it as type 0.
        if !types.contains(0) {
            let seen = Set(types).sorted().map(String.init).joined(separator: ", ")
            return explain("no Space reports type 0 (a normal desktop), only [\(seen)]; the type codes may have changed")
        }
        return nil
    }
}
