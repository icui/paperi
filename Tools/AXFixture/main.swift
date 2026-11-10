import AppKit

@MainActor final class PreviewButton: NSButton {
    var invoke: (() -> Void)?
    @objc func trigger() { invoke?() }
}

@MainActor final class PreviewWindow: NSWindow {
    var request: ((String, String) -> Void)?
    var stopButton: PreviewButton?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == [.command, .option], let key = event.charactersIgnoringModifiers?.lowercased(),
           let action = ["h": "shrink", "l": "grow", "i": "slurp", "o": "barf", "n": "nextSpace"][key] {
            request?(action, "keyEquivalent"); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { request?("stop", "keyEquivalent"); return }
        super.keyDown(with: event)
    }
}

// Disposable opt-in integration fixture. It operates only on its own windows,
// never activates another app, and exits without opening or saving documents.
@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var logURL: URL?
    private var tabWindows: [NSWindow] = []
    private var contentTabs: NSTabView?
    private var popup: NSWindow?
    private var sheet: NSWindow?
    private var previewSequence = 0

    private func makePreviewWindow(_ index: Int) -> PreviewWindow {
        let window = PreviewWindow(contentRect: NSRect(x: 120 + index * 40, y: 120, width: 420, height: 260),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let tokenIndex = CommandLine.arguments.firstIndex(of: "--preview-token")
        let token = tokenIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? ""
        window.title = "Paperi Preview — Disposable \(index + 1) [\(token)]"
        window.tabbingMode = .disallowed; window.tabbingIdentifier = "PaperiPreviewTabs"; window.isReleasedWhenClosed = false
        window.request = { [weak self, weak window] action, source in
            guard let self, let window else { return }
            self.previewSequence += 1
            self.log("previewCommand", extra: ["command": action, "source": source,
                "commandWindowID": window.windowNumber, "previewToken": token, "sequence": self.previewSequence])
        }
        let label = NSTextField(wrappingLabelWithString: "Disposable preview only\nClick a document to focus it.\n⌥⌘H / ⌥⌘L resize • ⌥⌘I / ⌥⌘O stack/unstack • ⌥⌘N next Space • Esc stops\nSupports native tabs (Window → Merge All Windows), stacked columns and cross-Space transfer.\nStop restores all surviving windows before closing.")
        let row1 = NSStackView(); row1.orientation = .horizontal; row1.spacing = 8; row1.setAccessibilityRole(.group)
        let row2 = NSStackView(); row2.orientation = .horizontal; row2.spacing = 8; row2.setAccessibilityRole(.group)
        for (idx, item) in [("Narrower", "shrink"), ("Wider", "grow"), ("Stack", "slurp"),
                            ("Unstack", "barf"), ("Next Space", "nextSpace"), ("Stop & Restore", "stop")].enumerated() {
            let button = PreviewButton(title: item.0, target: nil, action: nil)
            button.target = button; button.action = #selector(PreviewButton.trigger)
            button.invoke = { [weak window] in window?.request?(item.1, "button") }
            (idx < 3 ? row1 : row2).addArrangedSubview(button)
            if item.1 == "stop" { window.stopButton = button }
        }
        let stack = NSStackView(views: [label, row1, row2]); stack.orientation = .vertical; stack.setAccessibilityRole(.group)
        stack.alignment = .leading; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16)])
        }
        window.orderFrontRegardless()
        return window
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.count >= 2 { logURL = URL(fileURLWithPath: CommandLine.arguments[1]) }
        log("launched")
        NSApp.setActivationPolicy(CommandLine.arguments.contains("--accessory") ? .accessory : .regular)
        if CommandLine.arguments.contains("--space-tab-session") {
            let tokenIndex = CommandLine.arguments.firstIndex(of: "--preview-token")
            let token = tokenIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? ""
            after(1) {
                self.tabWindows = (0..<2).map { idx in
                    let w = self.makeTabWindow(idx)
                    w.title = "Paperi Space Tab [\(token)]"
                    return w
                }
            }
            after(3) { self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above) }
            after(5) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
            after(7) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
            after(65) { NSApp.terminate(nil) }
            return
        }
        if CommandLine.arguments.contains("--lifecycle-placement") {
            let preview = CommandLine.arguments.contains("--preview")
            after(1) {
                let window = preview ? self.makePreviewWindow(0) : self.makeTabWindow(0)
                window.tabbingMode = .disallowed
                self.tabWindows.append(window)
            }
            after(4) {
                let window = preview ? self.makePreviewWindow(1) : self.makeTabWindow(1)
                window.tabbingMode = .disallowed
                self.tabWindows.append(window)
            }
            if CommandLine.arguments.contains("--external-resize") {
                after(6) {
                    guard let window = self.tabWindows.first else { return }
                    window.setContentSize(NSSize(width: window.contentLayoutRect.width + 64,
                                                 height: window.contentLayoutRect.height))
                    self.log("externalResize")
                }
            }
            let interaction = CommandLine.arguments.contains("--interaction")
            if interaction {
                after(5) { self.tabWindows.first?.makeMain(); self.tabWindows.first?.makeKey() }
                after(7) {
                    let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 220, height: 120),
                                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false
                    self.popup = panel
                    panel.makeKeyAndOrderFront(nil)
                }
                after(9) {
                    self.popup?.close(); self.popup = nil
                    self.tabWindows.first?.makeMain(); self.tabWindows.first?.makeKey()
                }
            }
            if preview {
                if CommandLine.arguments.contains("--preview-input-test") {
                    after(5) { NSApp.activate(); self.tabWindows.first?.makeKeyAndOrderFront(nil) }
                    after(5.4) {
                        guard self.tabWindows.count == 2 else { return }
                        self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above)
                    }
                    after(6.0) {
                        guard self.tabWindows.count == 2 else { return }
                        self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1]
                    }
                    after(6.6) {
                        guard self.tabWindows.count == 2 else { return }
                        self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0]
                    }
                    after(7.4) {
                        guard self.tabWindows.count == 2 else { return }
                        self.tabWindows[0].tabGroup?.removeWindow(self.tabWindows[1])
                        self.tabWindows[1].orderFrontRegardless()
                        self.tabWindows[1].makeKeyAndOrderFront(nil)
                    }
                    for (second, key, code) in [(8.5, "l", UInt16(37)), (9.4, "h", UInt16(4)),
                                                (10.3, "i", UInt16(34)), (11.2, "o", UInt16(31))] {
                        after(second) {
                            guard let window = self.tabWindows.last as? PreviewWindow,
                                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                    modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: key,
                                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { return }
                            _ = window.performKeyEquivalent(with: event)
                        }
                    }
                    after(12.2) { (self.tabWindows.last as? PreviewWindow)?.stopButton?.performClick(nil) }
                }
                after(65) { NSApp.terminate(nil) }
            } else {
                after(interaction ? 12 : 9) { self.tabWindows.first?.close() }
                after(interaction ? 14 : 12) { self.tabWindows.last?.close() }
                after(interaction ? 16 : 14) { NSApp.terminate(nil) }
            }
            return
        }
        if CommandLine.arguments.contains("--placement") {
            after(1) {
                self.window = self.makeTabWindow(0)
                self.window?.tabbingMode = .disallowed
                self.log("placementReady")
            }
            after(15) { self.window?.close(); NSApp.terminate(nil) }
            return
        }
        if CommandLine.arguments.contains("--popups") { runPopups(); return }
        if CommandLine.arguments.contains("--unvisited-tabs") { runUnvisitedTabs(); return }
        if CommandLine.arguments.contains("--multi-tabs") { runMultipleTabGroups(); return }
        if CommandLine.arguments.contains("--tab-session") { runTabSession(); return }
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

    private func runPopups() {
        after(1) { self.window = self.makeTabWindow(0) }
        after(3) {
            let panel = NSPanel(contentRect: NSRect(x: 180, y: 160, width: 240, height: 160),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            self.popup = panel
            self.window?.addChildWindow(panel, ordered: .above)
            panel.orderFrontRegardless()
        }
        after(5) {
            if let popup = self.popup { self.window?.removeChildWindow(popup); popup.close() }
            self.popup = nil
            self.window?.setFrameOrigin(NSPoint(x: 160, y: 140))
        }
        after(7) {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 160),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            self.sheet = sheet
            self.window?.beginSheet(sheet)
        }
        after(9) {
            if let sheet = self.sheet { self.window?.endSheet(sheet); sheet.close() }
            self.sheet = nil
            self.window?.setFrameOrigin(NSPoint(x: 200, y: 160))
        }
        after(11) { self.window?.close(); self.window = nil }
        after(13) { self.log("terminating"); NSApp.terminate(nil) }
    }

    private func runTabSession() {
        after(1) { self.tabWindows = (0..<2).map { self.makeTabWindow($0) } }
        after(3) { self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above) }
        // Visit both controls before testing managed representative changes.
        after(5) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
        after(7) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
        after(9) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
        after(11) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
        after(13) {
            self.tabWindows[0].tabGroup?.removeWindow(self.tabWindows[1])
            self.tabWindows[1].orderFrontRegardless()
        }
        after(15) { self.tabWindows[0].addTabbedWindow(self.tabWindows[1], ordered: .above) }
        if CommandLine.arguments.contains("--tab-reconcile") {
            after(17) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
            after(19) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
            after(21) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
            if CommandLine.arguments.contains("--tab-growth") {
                after(23) {
                    let added = self.makeTabWindow(2)
                    self.tabWindows.append(added)
                    self.tabWindows[0].addTabbedWindow(added, ordered: .above)
                    self.tabWindows[0].tabGroup?.selectedWindow = added
                }
                after(25) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
                after(27) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
                after(29) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[2] }
                after(31) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
                after(33) {
                    self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[2]
                    self.tabWindows[2].close()
                }
                after(35) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
                after(37) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1] }
                after(39) { self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[0] }
                after(41) {
                    self.tabWindows[0].tabGroup?.selectedWindow = self.tabWindows[1]
                    self.tabWindows[1].close()
                }
                after(47) { for window in self.tabWindows { window.close() } }
                after(49) { self.log("terminating"); NSApp.terminate(nil) }
            } else {
                after(23) { self.tabWindows[0].tabGroup?.selectedWindow?.close() }
                after(25) { for window in self.tabWindows { window.close() } }
                after(27) { self.log("terminating"); NSApp.terminate(nil) }
            }
        } else {
            after(17) { self.tabWindows[0].tabGroup?.selectedWindow?.close() }
            after(19) { for window in self.tabWindows { window.close() } }
            after(21) { self.log("terminating"); NSApp.terminate(nil) }
        }
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
            let count = CommandLine.arguments.contains("--partial-tabs") ? 6 : 5
            self.tabWindows = (0..<count).map { self.makeTabWindow($0) }
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
            if CommandLine.arguments.contains("--partial-tabs") {
                self.tabWindows[2].addTabbedWindow(self.tabWindows[5], ordered: .above)
                self.tabWindows[2].tabGroup?.selectedWindow = self.tabWindows[2]
            }
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
        let startupDelay = CommandLine.arguments.contains("--accessory") ? 3.0 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + startupDelay) {
            action()
            self.log("action-\(seconds)")
        }
    }

    private func log(_ event: String, extra: [String: Any] = [:]) {
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
        if event == "externalResize", let window = tabWindows.first {
            row["externalResizeWidth"] = window.frame.width
        }
        if CommandLine.arguments.contains("--placement") {
            row["documentID"] = window?.windowNumber ?? 0
        }
        if let tabs = contentTabs, let selected = tabs.selectedTabViewItem {
            row["contentTab"] = tabs.indexOfTabViewItem(selected)
            row["contentWindow"] = tabWindows[4].windowNumber
        }
        if CommandLine.arguments.contains("--popups") {
            row["documentID"] = window?.windowNumber ?? 0
            row["documentVisible"] = window?.isVisible ?? false
            row["panelID"] = popup?.windowNumber ?? 0
            row["panelVisible"] = popup?.isVisible ?? false
            row["sheetID"] = sheet?.windowNumber ?? 0
            row["sheetVisible"] = sheet?.isVisible ?? false
            row["attachedSheetID"] = window?.attachedSheet?.windowNumber ?? 0
        }
        row.merge(extra) { _, new in new }
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
