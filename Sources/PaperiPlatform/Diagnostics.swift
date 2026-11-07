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
    private final class Subscription {
        let observer: AXObserver
        weak var owner: EventRecorder?
        var windows: [(element: AXUIElement, id: UInt32)] = []
        init(observer: AXObserver, owner: EventRecorder) {
            self.observer = observer
            self.owner = owner
        }
        deinit {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
    private final class WorkspaceObservation {
        let token: NSObjectProtocol
        let center: NotificationCenter
        init(_ token: NSObjectProtocol, center: NotificationCenter) { self.token = token; self.center = center }
        deinit { center.removeObserver(token) }
    }
    private var observers: [pid_t: Subscription] = [:]
    private var workspaceTokens: [WorkspaceObservation] = []
    private var running = false
    public init() {}
    public func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(WorkspaceObservation(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let event = notification.name.rawValue
                let launched = notification.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if launched {
                        self.attach(pid)
                    } else {
                        self.detach(pid)
                    }
                    Diagnostics.printJSON(["event": event, "pid": pid,
                                           "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
                }
            }, center: center))
        }
        for app in NSWorkspace.shared.runningApplications {
            attach(app.processIdentifier)
        }
        Diagnostics.printJSON(["event": "recorderReady", "observerCount": observers.count,
                               "windowReferenceCount": observers.values.reduce(0) { $0 + $1.windows.count },
                               "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
    }

    private func attach(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier, observers[pid] == nil else { return }
        var value: AXObserver?
        let result = AXObserverCreate(pid, { observer, element, notification, context in
            guard let context else { return }
            // Every observer source is installed exclusively on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<Subscription>.fromOpaque(context).takeUnretainedValue().owner?
                    .receive(observer, element: element, notification: notification as String)
            }
        }, &value)
        guard result == .success, let observer = value else {
            report(result, pid: pid, notification: "AXObserverCreate")
            return
        }
        observers[pid] = Subscription(observer: observer, owner: self)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            subscribe(observer, element: element, name: name, pid: pid)
        }
        if let windows = Diagnostics.attribute(element, kAXWindowsAttribute) as? [AXUIElement] {
            for window in windows { attachWindow(window, pid: pid) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func attachWindow(_ window: AXUIElement, pid: pid_t) {
        guard let subscription = observers[pid],
              !subscription.windows.contains(where: { CFEqual($0.element, window) }) else { return }
        AXUIElementSetMessagingTimeout(window, 0.15)
        subscription.windows.append((window, paperi_window_id(window)))
        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                     kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            subscribe(subscription.observer, element: window, name: name, pid: pid)
        }
    }

    private func subscribe(_ observer: AXObserver, element: AXUIElement, name: String, pid: pid_t) {
        guard let subscription = observers[pid] else { return }
        let result = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(subscription).toOpaque())
        if result != .success && result != .notificationAlreadyRegistered { report(result, pid: pid, notification: name) }
    }

    private func report(_ error: AXError, pid: pid_t, notification: String) {
        Diagnostics.printJSON(["event": "subscriptionFailed", "pid": pid, "notification": notification,
                               "axError": error.rawValue, "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
    }

    private func receive(_ observer: AXObserver, element: AXUIElement, notification: String) {
        guard running, let pid = observers.first(where: { CFEqual($0.value.observer, observer) })?.key else { return }
        let cachedID = observers[pid]?.windows.first(where: { CFEqual($0.element, element) })?.id ?? 0
        let id = cachedID != 0 ? cachedID : paperi_window_id(element)
        Diagnostics.printJSON(["event": notification, "pid": pid, "windowID": id,
                               "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
        if notification == kAXUIElementDestroyedNotification {
            observers[pid]?.windows.removeAll { CFEqual($0.element, element) }
        } else if notification == kAXWindowCreatedNotification {
            attachWindow(element, pid: pid)
        } else if notification == kAXFocusedWindowChangedNotification || notification == kAXMainWindowChangedNotification {
            if Diagnostics.attribute(element, kAXRoleAttribute) as? String == kAXWindowRole {
                attachWindow(element, pid: pid)
            } else {
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.15)
                if let window = Diagnostics.attribute(application, kAXFocusedWindowAttribute),
                   CFGetTypeID(window) == AXUIElementGetTypeID() {
                    attachWindow(window as! AXUIElement, pid: pid)
                }
            }
        }
    }

    private func detach(_ pid: pid_t) {
        guard let subscription = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(subscription.observer), .commonModes)
    }

    public func stop() {
        running = false
        workspaceTokens.removeAll()
        for pid in Array(observers.keys) { detach(pid) }
    }
}
