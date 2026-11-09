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
                        fullscreen: attribute(ref, "AXFullScreen") as? Bool,
                        minimized: attribute(ref, kAXMinimizedAttribute) as? Bool, level: levels[id])
                    let classification = WindowPolicy.classify(facts)
                    var row: [String: Any] = ["id": id, "pid": app.processIdentifier, "bundleID": facts.bundleID,
                        "role": facts.role ?? "unknown", "subrole": facts.subrole ?? "unknown",
                        "eligibility": classification.eligibility.rawValue, "reason": classification.reason,
                        "appFocusedWindow": focused.map { CFEqual($0, ref) } ?? false,
                        "applicationActive": app.isActive,
                        "spaces": paperi_copy_window_spaces(id).map { $0 as NSArray } ?? [],
                        "fullscreen": facts.fullscreen.map { $0 as Any } ?? NSNull(),
                        "minimized": facts.minimized.map { $0 as Any } ?? NSNull()]
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
        return ["schemaVersion": 2, "timestamp": ISO8601DateFormatter().string(from: Date()),
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
            // Readiness must reach pipe consumers before interactions begin.
            FileHandle.standardOutput.write(data + Data([0x0a]))
        } catch { FileHandle.standardError.write(Data("Cannot encode diagnostics: \(error)\n".utf8)) }
    }
}

/// Read-only AX trace. Runs on the main run loop; no window writes or hotkeys.
@MainActor public final class EventRecorder {
    private final class Subscription {
        let observer: AXObserver
        let source: RecorderSource
        let runID: UUID
        weak var owner: EventRecorder?
        var windows: [(element: AXUIElement, id: UInt32)] = []
        var notifications = NotificationSubscriptions()
        let evidenceIdentities = EvidenceIdentities()
        let selectionAssociations = SelectionAssociations()
        let finderTabIdentities = EvidenceIdentities()
        let finderTabAssociations = SelectionAssociations()
        let nativeTabIdentities = EvidenceIdentities()
        let nativeTabAssociations = SelectionAssociations()
        init(observer: AXObserver, owner: EventRecorder, runID: UUID) {
            self.observer = observer
            self.source = RecorderSource(AXObserverGetRunLoopSource(observer))
            self.owner = owner
            self.runID = runID
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
    private let retries = RecorderRetries()
    private var running = false
    private var runID = UUID()
    private let workspaceCenter: NotificationCenter
    private let runningApplications: () -> [NSRunningApplication]
    private let emit: ([String: Any]) -> Void
    private let bundleIDs: Set<String>?
    private let observeWorkspaceEvents: Bool

    public convenience init(bundleIDs: Set<String>? = nil, observeWorkspaceEvents: Bool = true) {
        self.init(workspaceCenter: NSWorkspace.shared.notificationCenter,
                  runningApplications: { NSWorkspace.shared.runningApplications },
                  bundleIDs: bundleIDs, observeWorkspaceEvents: observeWorkspaceEvents,
                  emit: { Diagnostics.printJSON($0, pretty: false) })
    }

    // Isolated workspace inputs allow lifecycle tests without observing other apps.
    init(workspaceCenter: NotificationCenter,
         runningApplications: @escaping () -> [NSRunningApplication],
         bundleIDs: Set<String>? = nil,
         observeWorkspaceEvents: Bool = true,
         emit: @escaping ([String: Any]) -> Void) {
        self.workspaceCenter = workspaceCenter
        self.runningApplications = runningApplications
        self.emit = emit
        self.bundleIDs = bundleIDs
        self.observeWorkspaceEvents = observeWorkspaceEvents
    }
    public func start() {
        guard !running else { return }
        running = true
        let runID = UUID()
        self.runID = runID
        let center = workspaceCenter
        let names = observeWorkspaceEvents ? [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] : []
        for name in names {
            workspaceTokens.append(WorkspaceObservation(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let event = notification.name.rawValue
                let launched = notification.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated {
                    guard let self, self.running, self.runID == runID else { return }
                    guard self.includes(app) else { return }
                    if launched {
                        self.attach(pid)
                        self.scheduleRetries(pid)
                    } else {
                        self.detach(pid)
                    }
                    self.emit(["event": event, "pid": pid,
                               "uptime": ProcessInfo.processInfo.systemUptime])
                }
            }, center: center))
        }
        for app in runningApplications() where includes(app) {
            attach(app.processIdentifier)
            scheduleRetries(app.processIdentifier)
        }
        emit(["event": "recorderReady", "observerCount": observers.count,
              "workspaceEventsEnabled": observeWorkspaceEvents,
              "windowReferenceCount": observers.values.reduce(0) { $0 + $1.windows.count },
              "uptime": ProcessInfo.processInfo.systemUptime])
    }

    /// Explicit fresh discovery. Missing apps/windows never become removal events.
    public func reconcileNow() {
        guard running else { return }
        var attempted = 0
        for app in runningApplications() where includes(app) && !app.isTerminated &&
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let pid = app.processIdentifier
            let needsStartup = observers[pid] == nil
            attach(pid)
            if needsStartup { scheduleRetries(pid) }
            attempted += 1
        }
        emit(["event": "recorderReconciled", "applicationAttempts": attempted,
              "observerCount": observers.count,
              "uptime": ProcessInfo.processInfo.systemUptime])
    }

    private func includes(_ app: NSRunningApplication) -> Bool {
        guard let bundleIDs else { return true }
        return app.bundleIdentifier.map { bundleIDs.contains($0) } ?? false
    }

    public func tabEvidence(bundleID: String) -> [String: Any] {
        var report = Diagnostics.tabEvidence(bundleID: bundleID,
            observedWindows: observers.mapValues { $0.windows.map(\.element) },
            identities: observers.mapValues(\.evidenceIdentities),
            associations: observers.mapValues(\.selectionAssociations))
        if bundleID == "com.apple.finder" {
            report["finderTabBarEvidence"] = Diagnostics.tabEvidence(bundleID: bundleID,
                observedWindows: observers.mapValues { $0.windows.map(\.element) },
                identities: observers.mapValues(\.finderTabIdentities),
                associations: observers.mapValues(\.finderTabAssociations), finderTabBarOnly: true)
        }
        var native = Diagnostics.tabEvidence(bundleID: bundleID, observedWindows: [:],
            identities: observers.mapValues(\.nativeTabIdentities),
            associations: observers.mapValues(\.nativeTabAssociations), windowTabBarOnly: true)
        native["applications"] = (native["applications"] as? [[String: Any]] ?? []).map { app in
            var result = app
            result["membershipCandidates"] = NativeTabMembership.inspect(app).map {
                ["scope": $0.scope, "group": $0.group, "members": $0.members, "active": $0.active] as [String: Any]
            }
            return result
        }
        report["nativeTabEvidence"] = native
        return report
    }

    public func windowEvidence(bundleID: String) -> [String: Any] {
        Diagnostics.windowEvidence(bundleID: bundleID,
            observedWindows: observers.mapValues { $0.windows.map(\.element) })
    }

    /// PID-scoped evidence for a child already owned by an integration probe.
    func tabEvidence(processID: pid_t) -> [String: Any] {
        // Fresh enumerated representatives supply tab bars. Cached inactive
        // references are validated separately, not traversed as content trees.
        Diagnostics.tabEvidence(bundleID: "disposable-child", observedWindows: [:],
            identities: observers.mapValues(\.evidenceIdentities), associations: observers.mapValues(\.selectionAssociations),
            processID: processID, windowTabBarOnly: true)
    }

    private func attach(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        if observers[pid] != nil {
            reconcile(pid)
            return
        }
        var value: AXObserver?
        let result = AXObserverCreate(pid, { observer, element, notification, context in
            guard let context else { return }
            // Every observer source is installed exclusively on the main run loop.
            MainActor.assumeIsolated {
                let subscription = Unmanaged<Subscription>.fromOpaque(context).takeUnretainedValue()
                subscription.owner?.receive(observer, element: element, notification: notification as String,
                                            runID: subscription.runID)
            }
        }, &value)
        guard result == .success, let observer = value else {
            report(result, pid: pid, notification: "AXObserverCreate")
            return
        }
        observers[pid] = Subscription(observer: observer, owner: self, runID: runID)
        reconcile(pid)
    }

    private func reconcile(_ pid: pid_t) {
        guard let observer = observers[pid]?.observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            subscribe(observer, element: element, name: name, pid: pid)
        }
        var errors: [String: Int32] = [:]
        func read(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            errors[name] = result.rawValue
            return result == .success ? value : nil
        }
        func reference(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        let enumerated = read(kAXWindowsAttribute) as? [AXUIElement] ?? []
        let focused = reference(read(kAXFocusedWindowAttribute))
        let main = reference(read(kAXMainWindowAttribute))
        // Inspect only direct children, never descend into application/menu trees.
        let children = read(kAXChildrenAttribute) as? [AXUIElement] ?? []
        let discovery = RecorderWindowDiscovery.collect(enumerated: enumerated, focused: focused, main: main,
                                                      children: Array(children.prefix(128)), pid: pid) { window in
            AXUIElementSetMessagingTimeout(window, 0.15)
            var owner: pid_t = 0
            let result = AXUIElementGetPid(window, &owner)
            return (result == .success ? owner : nil, Diagnostics.attribute(window, kAXRoleAttribute) as? String)
        }
        for window in discovery.windows { attachWindow(window.element, pid: pid) }
        emit(["event": "windowDiscovery", "pid": pid, "queryErrors": errors,
              "enumeratedCount": enumerated.count, "rejectedCount": discovery.rejectedCount,
              "directChildCount": children.count, "directChildrenTruncated": children.count > 128,
              "windows": discovery.windows.map { window in
                  ["windowID": observers[pid]?.windows.first(where: { CFEqual($0.element, window.element) })?.id ?? 0,
                   "sources": window.sources.sorted()] as [String: Any]
              }, "uptime": ProcessInfo.processInfo.systemUptime])
    }

    /// Three startup passes at approximately 1, 3 and 7 seconds. Absence from
    /// enumeration never removes a reference or implies that a window closed.
    private func scheduleRetries(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        retries.schedule(pid) { [weak self] in
            guard let self, self.running,
                  let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            self.attach(pid)
            self.emit(["event": "subscriptionRetry", "pid": pid,
                       "uptime": ProcessInfo.processInfo.systemUptime])
            return true
        }
    }

    private func attachWindow(_ window: AXUIElement, pid: pid_t) {
        guard let subscription = observers[pid] else { return }
        AXUIElementSetMessagingTimeout(window, 0.15)
        if let index = subscription.windows.firstIndex(where: { CFEqual($0.element, window) }) {
            if subscription.windows[index].id == 0 {
                subscription.windows[index].id = paperi_window_id(window)
            }
        } else {
            subscription.windows.append((window, paperi_window_id(window)))
        }
        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                     kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            subscribe(subscription.observer, element: window, name: name, pid: pid)
        }
    }

    private func subscribe(_ observer: AXObserver, element: AXUIElement, name: String, pid: pid_t) {
        guard let subscription = observers[pid] else { return }
        guard let result = subscription.notifications.register(element, name: name, perform: {
            AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(subscription).toOpaque())
        }) else { return }
        if result != .success && result != .notificationAlreadyRegistered { report(result, pid: pid, notification: name) }
    }

    private func report(_ error: AXError, pid: pid_t, notification: String) {
        emit(["event": "subscriptionFailed", "pid": pid, "notification": notification,
              "axError": error.rawValue, "uptime": ProcessInfo.processInfo.systemUptime])
    }

    private func receive(_ observer: AXObserver, element: AXUIElement, notification: String, runID: UUID) {
        guard running, self.runID == runID,
              let pid = observers.first(where: { CFEqual($0.value.observer, observer) })?.key else { return }
        let cachedID = observers[pid]?.windows.first(where: { CFEqual($0.element, element) })?.id ?? 0
        let id = cachedID != 0 ? cachedID : paperi_window_id(element)
        emit(["event": notification, "pid": pid, "windowID": id,
              "uptime": ProcessInfo.processInfo.systemUptime])
        if notification == kAXUIElementDestroyedNotification {
            observers[pid]?.selectionAssociations.invalidate(reason: .windowDestroyed)
            observers[pid]?.finderTabAssociations.invalidate(reason: .windowDestroyed)
            observers[pid]?.nativeTabAssociations.invalidate(reason: .windowDestroyed)
            observers[pid]?.notifications.remove(element)
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

    @discardableResult private func detach(_ pid: pid_t) -> Bool {
        retries.cancel(pid)
        guard let subscription = observers.removeValue(forKey: pid) else { return true }
        return subscription.source.remove()
    }

    /// Reports actual native source removal before releasing observer ownership.
    @discardableResult public func stop() -> [String: Any] {
        running = false
        runID = UUID()
        workspaceTokens.removeAll()
        retries.cancelAll()
        let count = observers.count
        var remaining = 0
        for pid in Array(observers.keys) {
            if !detach(pid) { remaining += 1 }
        }
        return ["detachedObserverCount": count, "sourcesStillInstalled": remaining,
                "workspaceObserverCount": workspaceTokens.count]
    }
}
