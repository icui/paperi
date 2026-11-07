import AppKit

// Disposable opt-in integration fixture. It operates only on its own windows,
// never activates another app, and exits without opening or saving documents.
@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var logURL: URL?
    private var tabWindows: [NSWindow] = []
    private var contentTabs: NSTabView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.count >= 2 { logURL = URL(fileURLWithPath: CommandLine.arguments[1]) }
        log("launched")
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--unvisited-tabs") { runUnvisitedTabs(); return }
        if CommandLine.arguments.contains("--multi-tabs") { runMultipleTabGroups(); return }
        if CommandLine.arguments.contains("--tabs") { runTabs(); return }
        after(1) {
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 420, height: 260),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Paperi disposable AX fixture"
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            self.window = window
            window.orderFrontRegardless()
        }
        after(2) { self.window?.setFrameOrigin(NSPoint(x: 160, y: 150)) }
        after(3) { self.window?.setContentSize(NSSize(width: 460, height: 300)) }
        after(4) { self.window?.miniaturize(nil) }
        after(6) { self.window?.deminiaturize(nil) }
        after(8) { self.window?.close(); self.window = nil }
        after(9) { self.log("terminating"); NSApp.terminate(nil) }
    }

    private func runTabs() {
        after(1) {
            self.tabWindows = (0..<2).map { self.makeTabWindow($0) }
        }
        after(3) { self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above) }
        after(5) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
        after(7) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
        if CommandLine.arguments.contains("--restart-check") { after(8) {} }
        after(9) {
            self.tabWindows[0].tabGroup?.removeWindow(self.tabWindows[1])
            self.tabWindows[1].orderFrontRegardless()
        }
        after(11) { self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above) }
        after(13) { self.tabWindows[0].tabGroup?.selectedWindow?.close() }
        after(15) { for window in self.tabWindows { window.close() } }
        after(17) { self.log("terminating"); NSApp.terminate(nil) }
    }

    private func runUnvisitedTabs() {
        after(1) { self.tabWindows = (0..<3).map { self.makeTabWindow($0) } }
        after(3) {
            self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above)
            self.tabWindows[0].addTabbedWindow(self.tabWindows[2], ordered: .above)
            self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0]
        }
        after(5) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
        after(7) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
        after(9) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[2] }
        after(10) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
        after(11) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
        after(13) { self.tabWindows[0].tabGroup?.selectedWindow?.close() }
        after(15) { for window in self.tabWindows { window.close() } }
        after(17) { self.log("terminating"); NSApp.terminate(nil) }
    }

    private func makeTabWindow(_ index: Int) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 120 + index * 40, y: 120, width: 420, height: 260),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        // Deliberately identical titles: no title-based association is valid.
        window.title = "Paperi native-tab fixture"
        window.tabbingMode = .disallowed
        window.tabbingIdentifier = "PaperiFixtureTabs"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private func runMultipleTabGroups() {
        after(1) {
            self.tabWindows = (0..<5).map { self.makeTabWindow($0) }
            if CommandLine.arguments.contains("--content-tabs") {
                let tabs = NSTabView(frame: self.tabWindows[4].contentView!.bounds)
                tabs.autoresizingMask = [.width, .height]
                for index in 0..<2 {
                    let item = NSTabViewItem(identifier: index)
                    item.label = "Content tab"
                    item.view = NSView()
                    tabs.addTabViewItem(item)
                }
                self.tabWindows[4].contentView = tabs
                self.contentTabs = tabs
            }
        }
        after(3) {
            self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above)
            self.tabWindows[2].addTabbedWindow(self.tabWindows[3], ordered: .above)
            self.contentTabs?.selectTabViewItem(at: 1)
        }
        after(5) {
            self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1]
            self.tabWindows[2].tabGroup?.selectedWindow = self.tabWindows[3]
            self.contentTabs?.selectTabViewItem(at: 0)
        }
        after(7) {
            self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0]
            self.tabWindows[2].tabGroup?.selectedWindow = self.tabWindows[2]
            self.contentTabs?.selectTabViewItem(at: 1)
        }
        after(9) {
            self.tabWindows[0].tabGroup?.removeWindow(self.tabWindows[1])
            self.tabWindows[1].orderFrontRegardless()
        }
        after(11) { self.tabWindows[2].addTabbedWindow(self.tabWindows[1], ordered: .above) }
        after(13) { self.tabWindows[2].tabGroup?.selectedWindow?.close() }
        after(15) { for window in self.tabWindows { window.close() } }
        after(17) { self.log("terminating"); NSApp.terminate(nil) }
    }

    private func after(_ seconds: Double, action: @escaping @MainActor () -> Void) {
        let delay: Double
        if CommandLine.arguments.contains("--restart-check") {
            // Leave a wide quiet interval after selection-back for teardown.
            delay = seconds * 2 + (seconds >= 8 ? 4 : 0)
        } else {
            delay = CommandLine.arguments.contains("--unvisited-tabs") ? seconds * 1.5 : seconds
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            action()
            self.log("action-\(seconds)")
        }
    }

    private func log(_ event: String) {
        guard let logURL else { return }
        var row: [String: Any] = ["event": event, "pid": ProcessInfo.processInfo.processIdentifier,
                                  "uptime": ProcessInfo.processInfo.systemUptime,
                                  "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
                                  "workspaceBundleID": NSRunningApplication.current.bundleIdentifier ?? "unknown"]
        row["tabWindows"] = tabWindows.map { window in
            ["id": window.windowNumber, "visible": window.isVisible,
             "members": window.tabbedWindows?.map(\.windowNumber) ?? [],
             "selected": window.tabGroup?.selectedWindow?.windowNumber ?? 0] as [String: Any]
        }
        if let tabs = contentTabs, let selected = tabs.selectedTabViewItem {
            row["contentTab"] = tabs.indexOfTabViewItem(selected)
            row["contentWindow"] = tabWindows[4].windowNumber
        }
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([0x0a]))
        }
    }
}

let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.run()
