import Foundation

/// Detection of conflicting system trackpad gestures.
///
/// If macOS is configured to use three-finger gestures for Spaces, Mission Control
/// or Accessibility three-finger drag, Paperi's three-finger swipe gesture must be
/// disabled to prevent conflicting interpretations.
public enum GestureConflict {
    public static let trackpadDomains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]

    public static func conflictingKeys(fingers: Int) -> [String: String] {
        if fingers == 4 {
            return [
                "TrackpadFourFingerHorizSwipeGesture": "Swipe between full-screen apps (four fingers)",
                "TrackpadFourFingerVertSwipeGesture": "Mission Control (four fingers)"
            ]
        } else {
            return [
                "TrackpadThreeFingerHorizSwipeGesture": "Swipe between pages or full-screen apps (three fingers)",
                "TrackpadThreeFingerVertSwipeGesture": "Mission Control or App Exposé (three fingers)",
                "TrackpadThreeFingerDrag": "Three-finger drag"
            ]
        }
    }

    /// Evaluates dictionary representations of preference domains.
    /// Returns descriptions of any conflicts found.
    public static func conflicts(in domains: [String: [String: Any]], fingers: Int = 3) -> [String] {
        let keys = conflictingKeys(fingers: fingers)
        var blocked: [String] = []
        for (domainName, prefs) in domains {
            for (key, desc) in keys {
                guard let val = prefs[key] else {
                    blocked.append("\(desc) (\(key) missing in \(domainName))")
                    continue
                }
                let intVal: Int
                if let num = val as? NSNumber { intVal = num.intValue }
                else if let str = val as? String, let parsed = Int(str) { intVal = parsed }
                else if let b = val as? Bool { intVal = b ? 1 : 0 }
                else {
                    blocked.append("\(desc) (invalid value for \(key) in \(domainName))")
                    continue
                }
                if intVal != 0 {
                    blocked.append("\(desc) (\(key) = \(intVal) in \(domainName))")
                }
            }
        }
        return blocked
    }

    /// Reads live preferences using CFPreferencesCopyAppValue after synchronizing.
    public static func checkLive(fingers: Int = 3) -> [String] {
        var domains: [String: [String: Any]] = [:]
        for domain in trackpadDomains {
            CFPreferencesAppSynchronize(domain as CFString)
            var dict: [String: Any] = [:]
            for (key, _) in conflictingKeys(fingers: fingers) {
                if let val = CFPreferencesCopyAppValue(key as CFString, domain as CFString) {
                    dict[key] = val
                }
            }
            if !dict.isEmpty {
                domains[domain] = dict
            }
        }
        if domains.isEmpty {
            return ["No trackpad preferences found"]
        }
        return conflicts(in: domains, fingers: fingers)
    }
}
