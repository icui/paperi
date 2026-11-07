import AppKit

// Disposable opt-in integration fixture. It operates only on its own window,
// never activates another app, and exits without opening or saving documents.
@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var logURL: URL?
    private var tabWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.count >= 2 { logURL = URL(fileURLWithPath: CommandLine.arguments[1]) }
        log("launched")
        NSApp.setActivationPolicy(.regular)
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
            self.tabWindows = (0..<2).map { index in
                let window = NSWindow(contentRect: NSRect(x: 120 + index * 80, y: 120, width: 420, height: 260),
                                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "Paperi native-tab fixture \(index)"
                window.tabbingMode = .disallowed
                window.tabbingIdentifier = "PaperiFixtureTabs"
                window.isReleasedWhenClosed = false
                window.orderFrontRegardless()
                return window
            }
        }
        after(3) { self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above) }
        after(5) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
        after(7) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
        after(9) {
            self.tabWindows[0].tabGroup?.removeWindow(self.tabWindows[1])
            self.tabWindows[1].orderFrontRegardless()
        }
        after(11) { self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above) }
        after(13) { self.tabWindows[0].tabGroup?.selectedWindow?.close() }
        after(15) { for window in self.tabWindows { window.close() } }
        after(17) { self.log("terminating"); NSApp.terminate(nil) }
    }

    private func after(_ seconds: Double, action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            action()
            self.log("action-\(seconds)")
        }
    }

    private func log(_ event: String) {
        guard let logURL else { return }
        var row: [String: Any] = ["event": event, "pid": ProcessInfo.processInfo.processIdentifier,
                                  "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
                                  "workspaceBundleID": NSRunningApplication.current.bundleIdentifier ?? "unknown"]
        row["tabWindows"] = tabWindows.map { window in
            ["id": window.windowNumber, "visible": window.isVisible,
             "members": window.tabbedWindows?.map(\.windowNumber) ?? [],
             "selected": window.tabGroup?.selectedWindow?.windowNumber ?? 0] as [String: Any]
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
