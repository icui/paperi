import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

public enum Diagnostics {
    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    public static func frame(_ element: AXUIElement) -> Rect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
    }
    @MainActor public static func snapshot(includeTitles: Bool = false) -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        let trusted = AXIsProcessTrusted()
        let spaces = paperi_copy_display_spaces().map { $0 as NSArray }
        let cgWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var levels: [UInt32: Int] = [:]
        for row in cgWindows {
            if let id = row[kCGWindowNumber as String] as? UInt32, let level = row[kCGWindowLayer as String] as? Int { levels[id] = level }
        }
        let displays: [[String: Any]] = NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            return ["id": id, "uuid": uuid ?? "unknown", "name": screen.localizedName,
                    "appKitFrame": rectJSON(screen.frame), "appKitVisibleFrame": rectJSON(screen.visibleFrame),
                    "scale": screen.backingScaleFactor]
        }
        var windows: [[String: Any]] = []
        if trusted {
            for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 0.15)
                guard let refs = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                let focused = attribute(element, kAXFocusedWindowAttribute)
                for ref in refs {
                    let id = paperi_window_id(ref)
                    let parent = attribute(ref, kAXParentAttribute)
                    var move = DarwinBoolean(false); var resize = DarwinBoolean(false)
                    let moveResult = AXUIElementIsAttributeSettable(ref, kAXPositionAttribute as CFString, &move)
                    let resizeResult = AXUIElementIsAttributeSettable(ref, kAXSizeAttribute as CFString, &resize)
                    let facts = WindowFacts(bundleID: app.bundleIdentifier ?? "", role: attribute(ref, kAXRoleAttribute) as? String,
                        subrole: attribute(ref, kAXSubroleAttribute) as? String,
                        isRoot: parent.map { CFEqual($0, element) },
                        movable: moveResult == .success ? move.boolValue : nil,
                        resizable: resizeResult == .success ? resize.boolValue : nil,
                        fullscreen: attribute(ref, "AXFullScreen") as? Bool ?? false,
                        minimized: attribute(ref, kAXMinimizedAttribute) as? Bool ?? false, level: levels[id])
                    let classification = WindowPolicy.classify(facts)
                    var row: [String: Any] = ["id": id, "pid": app.processIdentifier, "bundleID": facts.bundleID,
                        "role": facts.role ?? "unknown", "subrole": facts.subrole ?? "unknown",
                        "eligibility": classification.eligibility.rawValue, "reason": classification.reason,
                        "appFocusedWindow": focused.map { CFEqual($0, ref) } ?? false,
                        "applicationActive": app.isActive,
                        "spaces": paperi_copy_window_spaces(id).map { $0 as NSArray } ?? [],
                        "fullscreen": facts.fullscreen, "minimized": facts.minimized]
                    if let frame = frame(ref) { row["axFrame"] = ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height] }
                    if let tabs = attribute(ref, "AXTabs") as? [Any] { row["axTabCount"] = tabs.count }
                    if includeTitles { row["title"] = attribute(ref, kAXTitleAttribute) as? String ?? "" }
                    windows.append(row)
                }
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return ["schemaVersion": 1, "timestamp": ISO8601DateFormatter().string(from: Date()),
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": architecture,
                "accessibilityTrusted": trusted, "separateSpaces": NSScreen.screensHaveSeparateSpaces,
                "spacesAvailable": spaces != nil, "spaces": spaces ?? [], "displays": displays, "windows": windows,
                "snapshotDurationMS": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                "note": "Read-only discovery; snapshot duration is not command latency. Missing AXTabs does not mean no native tabs."]
    }
    private static func rectJSON(_ rect: NSRect) -> [String: Double] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
    }
    public static func printJSON(_ value: [String: Any], pretty: Bool = true) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch { FileHandle.standardError.write(Data("Cannot encode diagnostics: \(error)\n".utf8)) }
    }
}

/// Read-only AX trace. Runs on the main run loop; no window writes or hotkeys.
@MainActor public final class EventRecorder {
    private var observers: [AXObserver] = []
    public init() {}
    public func start() {
        for app in NSWorkspace.shared.runningApplications {
            var observer: AXObserver?
            let result = AXObserverCreate(app.processIdentifier, { _, element, notification, _ in
                Diagnostics.printJSON(["event": notification as String, "windowID": paperi_window_id(element),
                    "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
            }, &observer)
            guard result == .success, let observer else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, nil)
            }
            if let windows = Diagnostics.attribute(element, kAXWindowsAttribute) as? [AXUIElement] {
                for window in windows {
                    for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification] {
                        AXObserverAddNotification(observer, window, name as CFString, nil)
                    }
                }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers.append(observer)
        }
    }
    public func stop() {
        for observer in observers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll()
    }
}
