import AppKit
import ApplicationServices
import PaperiBridge
import PaperiCore

/// Test aid only: drags a window onto a Space thumbnail through the Mission
/// Control AX tree, as a user would, and confirms WindowServer Space membership.
/// Live mode never moves windows between Spaces; it follows the user's moves
/// (and only asks whether Mission Control is open).
/// Matches the window by its exact, unique title.
@MainActor enum SpaceTransfer {
    private static func pause(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func axChildren(_ element: AXUIElement, identifier: String) -> [AXUIElement] {
        guard let children = axValue(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return [] }
        return children.filter { (axValue($0, kAXIdentifierAttribute as String) as? String) == identifier }
    }

    private static func axCenter(_ element: AXUIElement) -> CGPoint? {
        if let raw = axValue(element, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 {
                return CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        guard let posRaw = axValue(element, kAXPositionAttribute as String),
              let sizeRaw = axValue(element, kAXSizeAttribute as String),
              CFGetTypeID(posRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &s), s.width > 0, s.height > 0 else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }

    /// Whether Mission Control is showing (its Dock AX group exists).
    static func missionControlOpen() -> Bool { missionControlGroup() != nil }

    private static func missionControlGroup() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return axChildren(app, identifier: "mc").first
    }

    private static func windowSpaces(_ windowID: UInt32) -> [UInt64] {
        (paperi_copy_window_spaces(windowID) as? [NSNumber] ?? []).map(\.uint64Value)
    }

    private static func displaySpaceIDs(containing spaceID: UInt64) -> [UInt64] {
        guard let displays = paperi_copy_display_spaces() as? [[String: Any]] else { return [] }
        for display in displays {
            let ids = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            if ids.contains(spaceID) { return ids }
        }
        return []
    }

    static func moveWindowViaMissionControl(windowID: UInt32, expectedTitle: String,
                                            toSpace destinationSpace: UInt64,
                                            screenOrigin: CGPoint = .zero,
                                            destinationDisplayBounds: CGRect? = nil,
                                            exitWithEscape: Bool = false,
                                            exitClickingTitle: String? = nil) -> [String: Any] {
        var report: [String: Any] = [
            "windowID": windowID,
            "destinationSpace": destinationSpace,
            "activeSpaceBefore": paperi_active_space(),
            "membershipBefore": windowSpaces(windowID),
            "transferred": false
        ]
        guard AXIsProcessTrusted(), windowID > 0, !expectedTitle.isEmpty else {
            report["failure"] = "Invalid window/title or missing Accessibility trust"
            return report
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let savedCursor = CGEvent(source: nil)?.location ?? .zero
        var buttonHeld = false
        var heldPoint = CGPoint.zero

        func postMouse(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            event.post(tap: .cghidEventTap)
            if type == .leftMouseDown || type == .leftMouseDragged {
                buttonHeld = true; heldPoint = point
            } else if type == .leftMouseUp {
                buttonHeld = false
            }
        }

        func postEscape() {
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }

        defer {
            if buttonHeld { postMouse(.leftMouseUp, heldPoint) }
            CGWarpMouseCursorPosition(savedCursor)
        }

        let mcURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: mcURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)

        var opened = false
        for _ in 0..<30 {
            if missionControlGroup() != nil { opened = true; break }
            pause(0.1)
        }
        report["missionControlOpened"] = opened
        guard opened else {
            report["failure"] = "Mission Control did not open"
            return report
        }

        func fail(_ reason: String) -> [String: Any] {
            report["failure"] = reason
            postEscape()
            pause(0.8)
            return report
        }

        postMouse(.mouseMoved, CGPoint(x: screenOrigin.x + 10, y: screenOrigin.y + 10))
        pause(0.8)

        var expandAttempts = 0
        var barSettled = false
        var start = CGPoint.zero
        var end = CGPoint.zero
        var targetThumbnails: [AXUIElement] = []
        var targetIndex = 0

        while true {
            guard let group = missionControlGroup() else {
                return fail("Mission Control closed before drag")
            }
            var windowElement: AXUIElement?
            var displayGroup: AXUIElement?
            for display in axChildren(group, identifier: "mc.display") {
                for list in axChildren(display, identifier: "mc.windows") {
                    for candidate in (axValue(list, kAXChildrenAttribute as String) as? [AXUIElement] ?? []) {
                        if (axValue(candidate, kAXTitleAttribute as String) as? String) == expectedTitle {
                            if windowElement != nil { return fail("Title matched more than one Mission Control window") }
                            windowElement = candidate; displayGroup = display
                        }
                    }
                }
            }
            guard let winEl = windowElement, let dispEl = displayGroup else {
                return fail("Owned window not found in Mission Control")
            }
            // The Spaces bar belongs to the display hosting the destination
            // Space, which differs from the window's display for display moves.
            var barDisplay = dispEl
            if let bounds = destinationDisplayBounds {
                barDisplay = axChildren(group, identifier: "mc.display").first { axCenter($0).map(bounds.contains) == true } ?? dispEl
            }
            var thumbnails: [AXUIElement] = []
            for spaces in axChildren(barDisplay, identifier: "mc.spaces") {
                for list in axChildren(spaces, identifier: "mc.spaces.list") {
                    thumbnails = axValue(list, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
                }
            }
            let spaceIDs = displaySpaceIDs(containing: destinationSpace)
            guard let idx = spaceIDs.firstIndex(of: destinationSpace), thumbnails.count == spaceIDs.count else {
                return fail("Space thumbnail order unverified")
            }
            guard let s = axCenter(winEl), let e = axCenter(thumbnails[idx]) else {
                return fail("Mission Control frame unavailable")
            }
            if e.y < screenOrigin.y + 8 {
                if expandAttempts >= 5 { return fail("Spaces bar did not expand") }
                expandAttempts += 1
                report["thumbnailExpandAttempts"] = expandAttempts
                postMouse(.mouseMoved, CGPoint(x: e.x, y: screenOrigin.y + 4))
                pause(0.1)
                postMouse(.mouseMoved, CGPoint(x: e.x + 2, y: screenOrigin.y))
                pause(0.8)
                continue
            }
            if !barSettled {
                barSettled = true
                pause(0.45)
                continue
            }
            start = s; end = e; targetThumbnails = thumbnails; targetIndex = idx
            break
        }

        if CGEventSource.buttonState(.hidSystemState, button: .left) {
            return fail("Physical mouse button held")
        }

        postMouse(.mouseMoved, start)
        pause(0.15)
        postMouse(.leftMouseDown, start)
        for step in 1...14 {
            pause(0.04)
            let t = CGFloat(step) / 14.0
            postMouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        pause(0.14)
        let drop = axCenter(targetThumbnails[targetIndex]) ?? end
        postMouse(.leftMouseDragged, drop)
        pause(0.45)
        postMouse(.leftMouseUp, drop)
        report["dragStart"] = [start.x, start.y]
        report["dragEnd"] = [drop.x, drop.y]

        pause(0.6)
        if exitWithEscape {
            postEscape()
        } else if let other = exitClickingTitle {
            // Leave by clicking another window's thumbnail, as a user would.
            let thumbnail = missionControlGroup().flatMap { group in
                axChildren(group, identifier: "mc.display").lazy
                    .flatMap { axChildren($0, identifier: "mc.windows") }
                    .flatMap { axValue($0, kAXChildrenAttribute as String) as? [AXUIElement] ?? [] }
                    .first { (axValue($0, kAXTitleAttribute as String) as? String) == other }
            }
            guard let point = thumbnail.flatMap(axCenter) else { return fail("Exit window not found in Mission Control") }
            postMouse(.mouseMoved, point)
            pause(0.05)
            postMouse(.leftMouseDown, point)
            pause(0.08)
            postMouse(.leftMouseUp, point)
        } else {
            let click = axCenter(targetThumbnails[targetIndex]) ?? drop
            postMouse(.mouseMoved, click)
            pause(0.05)
            postMouse(.leftMouseDown, click)
            pause(0.08)
            postMouse(.leftMouseUp, click)
        }

        pause(1.3)
        if missionControlGroup() != nil {
            postEscape()
            pause(0.8)
        }

        var confirmed = false
        for _ in 0..<30 {
            if windowSpaces(windowID) == [destinationSpace] && (exitWithEscape || exitClickingTitle != nil || paperi_active_space() == destinationSpace) {
                confirmed = true
                break
            }
            pause(0.1)
        }
        if confirmed {
            // Allow the macOS Space transition animation to finish before AX writes on the destination Space.
            pause(0.6)
        }
        report["membershipAfter"] = windowSpaces(windowID)
        report["activeSpaceAfter"] = paperi_active_space()
        report["transferred"] = confirmed
        return report
    }
}

extension Diagnostics {
    /// Drags a real window onto a Space thumbnail in Mission Control, as a user
    /// would, on whichever display hosts that Space. Used to exercise how live
    /// mode follows user Mission Control moves (same- and cross-display).
    @MainActor public static func missionControlMove(windowID: UInt32, toSpace space: UInt64,
                                                     exitWithEscape: Bool = false, exitClicking other: UInt32? = nil) -> [String: Any] {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]] ?? []
        guard let pid = rows.first?[kCGWindowOwnerPID as String] as? pid_t else { return ["failure": "window not found"] }
        let app = AXUIElementCreateApplication(pid)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let element = windows.first(where: { paperi_window_id($0) == windowID }),
              let title = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty else {
            return ["failure": "window has no AX title"]
        }
        var otherTitle: String?
        if let other {
            let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(other)) as? [[String: Any]] ?? []
            guard let otherPID = rows.first?[kCGWindowOwnerPID as String] as? pid_t,
                  let ref = (attribute(AXUIElementCreateApplication(otherPID), kAXWindowsAttribute) as? [AXUIElement] ?? [])
                    .first(where: { paperi_window_id($0) == other }),
                  let t = attribute(ref, kAXTitleAttribute) as? String, !t.isEmpty else { return ["failure": "exit window has no AX title"] }
            otherTitle = t
        }
        guard let display = DisplaySpaceCoordinator.liveTopologies().first(where: { $0.spaces.contains { $0.id == space } }) else {
            return ["failure": "unknown Space"]
        }
        var bounds = CGRect.zero
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "Main"
            if uuid == display.displayUUID { bounds = CGDisplayBounds(id) }
        }
        return SpaceTransfer.moveWindowViaMissionControl(windowID: windowID, expectedTitle: title, toSpace: space,
                                                        screenOrigin: bounds.origin, destinationDisplayBounds: bounds,
                                                        exitWithEscape: exitWithEscape, exitClickingTitle: otherTitle)
    }
}
