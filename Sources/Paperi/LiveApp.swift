import AppKit
@preconcurrency import ApplicationServices
import PaperiCore
import PaperiPlatform

/// `paperi run`: live manager + command socket + hot keys + menu bar item.
@MainActor final class LiveApp: NSObject, NSMenuDelegate {
    private var manager: LiveManager!
    private var server: LiveCommandServer?
    private var keys: HotKeyCenter!
    private var item: NSStatusItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var trustTimer: Timer?
    private var cliInclude: [String] = []
    private var cliSingletons: [String] = []
    private var hotkeysEnabled = true
    private var verbose = false
    private var hotkeyReport: (registered: Int, failures: [String: Int32], errors: [String]) = (0, [:], [])
    private var hotkeyBindings: [HotKeyBindings.Binding] = []
    /// Why management is paused because displays sit side by side; nil when
    /// not paused for that reason. Cleared (and management resumed) once the
    /// displays are stacked again.
    private var arrangementPause: String?
    private var arrangementRecheck: Timer?
    /// Whether management was running when the arrangement paused it.
    private var resumeWhenStacked = true
    private var arrangementCheck: DispatchWorkItem?
    private var settingsWindow: SettingsWindow?
    private var warning: NSPopover?
    private var gestureWarningShown = false

    static func main(_ arguments: [String]) -> Never {
        let app = LiveApp()
        app.parse(arguments)
        app.launch()
    }

    private func parse(_ arguments: [String]) {
        var i = 0
        var restore = true
        while i < arguments.count {
            switch arguments[i] {
            case "--app" where i + 1 < arguments.count: cliInclude.append(arguments[i + 1]); i += 1
            case "--singleton-app" where i + 1 < arguments.count: cliSingletons.append(arguments[i + 1]); i += 1
            case "--verbose", "-v": verbose = true
            case "--no-restore": restore = false
            case "--no-hotkeys": hotkeysEnabled = false
            default:
                print("Usage: paperi run [--app bundle.id ...] [--singleton-app bundle.id ...] [--verbose] [--no-restore] [--no-hotkeys]")
                exit(2)
            }
            i += 1
        }
        let config: LiveConfig
        do { config = try loadConfig() } catch {
            FileHandle.standardError.write(Data("paperi run: invalid \(LiveConfig.defaultURL.path): \(error)\n".utf8)); exit(2)
        }
        var options = LiveManager.Options(config: config)
        options.verbose = verbose; options.restoreOnStop = restore
        manager = LiveManager(options: options)
    }

    private func loadConfig() throws -> LiveConfig {
        var config = try LiveConfig.load()
        if !cliInclude.isEmpty { config.include = (config.include ?? []) + cliInclude }
        config.singleton += cliSingletons
        return config
    }

    private func launch() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        keys = HotKeyCenter { [weak self] command in self?.dispatch(command, source: "hotkey") }
        server = LiveCommandServer { [weak self] request in self?.dispatch(request, source: "socket") ?? ["ok": false] }
        do { try server?.start() } catch {
            FileHandle.standardError.write(Data("paperi run: \(error)\n".utf8)); exit(1)
        }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { [weak self] in self?.shutdown(0) } }
            source.resume(); signalSources.append(source)
        }
        installMenu()
        waitForTrustThenStart()
        app.run()
        shutdown(0)
    }

    /// Without Accessibility access, prompt once and keep polling instead of
    /// exiting, so a login item does not spin or spam prompts.
    private func waitForTrustThenStart() {
        if AXIsProcessTrusted() { startManaging(); return }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        FileHandle.standardError.write(Data("paperi run: waiting for Accessibility access…\n".utf8))
        item?.button?.title = " ⚠︎"
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustTimer?.invalidate(); self.trustTimer = nil
                self.startManaging()
            }
        }
    }

    private func startManaging() {
        let unsupported = Self.arrangementProblem()
        do {
            if let unsupported { try manager.startPaused(); arrangementPause = unsupported } else { try manager.start() }
        } catch {
            FileHandle.standardError.write(Data("paperi run: \(error)\n".utf8)); shutdown(1)
        }
        registerHotkeys()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleArrangementCheck() }
        }
        updateTitle()
        if let unsupported { showWarning(unsupported); log(unsupported) }
        updateArrangementRecheck()
        checkGestureSettings()
        Diagnostics.printJSON(["event": "paperiRunning",
                               "apps": manager.options.config.include?.sorted() ?? ["all regular apps"],
                               "socket": LiveCommandServer.defaultPath, "hotkeys": hotkeyReport.registered,
                               "hotkeyFailures": hotkeyReport.failures, "hotkeyConfigErrors": hotkeyReport.errors], pretty: false)
    }

    private func registerHotkeys() {
        guard hotkeysEnabled && manager.options.config.hotkeysEnabled else { keys.unregister(); hotkeyReport = (0, [:], []); hotkeyBindings = []; return }
        let resolved = HotKeyBindings.resolve(overrides: manager.options.config.hotkeys)
        hotkeyBindings = resolved.bindings
        let failures = keys.register(resolved.bindings)
        hotkeyReport = (keys.registeredCount, failures, resolved.errors)
        for error in resolved.errors { FileHandle.standardError.write(Data("[paperi] config: \(error)\n".utf8)) }
        for (key, status) in failures.sorted(by: { $0.key < $1.key }) {
            FileHandle.standardError.write(Data("[paperi] \(key) unavailable (OSStatus \(status)); held by another app?\n".utf8))
        }
    }

    // MARK: display arrangement

    /// Why management cannot run (private Space interfaces unusable, or
    /// unsupported display settings), else nil.
    private static func arrangementProblem() -> String? {
        DisplayArrangement.currentProblem()
    }

    private static func pauseLabel(_ reason: String) -> String {
        SkyLightHealth.isProblem(reason) ? "macOS compatibility" : "display settings"
    }

    /// While paused for a reason, re-check every few seconds: a private
    /// interface can be briefly unavailable (e.g. at login) without any
    /// display notification announcing that it recovered.
    private func updateArrangementRecheck() {
        if arrangementPause == nil {
            arrangementRecheck?.invalidate(); arrangementRecheck = nil
        } else if arrangementRecheck == nil {
            arrangementRecheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkArrangement() }
            }
        }
    }

    /// Displays settle over several notifications while being rearranged.
    private func scheduleArrangementCheck() {
        arrangementCheck?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { [weak self] in self?.checkArrangement() } }
        arrangementCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func checkArrangement() {
        guard let problem = Self.arrangementProblem() else {
            if arrangementPause != nil {
                arrangementPause = nil
                warning?.close()
                if resumeWhenStacked { manager.resume(); log("pause reason cleared: resumed") }
            }
            updateArrangementRecheck()
            updateTitle()
            return
        }
        // Already paused for this reason. A user pause is kept, but resuming
        // is refused while the displays stay side by side.
        guard arrangementPause != problem else { return }
        if arrangementPause == nil { resumeWhenStacked = !manager.paused }
        if !manager.paused { manager.pause() }
        arrangementPause = problem
        log(problem)
        updateArrangementRecheck()
        updateTitle()
        showWarning(problem)
    }

    /// A small popover under the menu bar item; it closes on its own.
    private func showWarning(_ text: String) {
        guard let button = item?.button else { return }
        warning?.close()
        let width: CGFloat = 300
        let compatibility = SkyLightHealth.isProblem(text)
        let title = NSTextField(wrappingLabelWithString: "Paperi paused: \(Self.pauseLabel(text))")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let body = NSTextField(wrappingLabelWithString: text)
        for label in [title, body] {
            label.preferredMaxLayoutWidth = width
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        let open = NSButton(title: "Open Display Settings", target: self, action: #selector(openDisplaySettings))
        open.bezelStyle = .rounded; open.keyEquivalent = "\r"
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissWarning))
        dismiss.bezelStyle = .rounded
        // Nothing in System Settings fixes an incompatible macOS interface.
        let buttons = NSStackView(views: compatibility ? [dismiss] : [dismiss, open])
        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let controller = NSViewController()
        controller.view = stack
        stack.layoutSubtreeIfNeeded()
        controller.preferredContentSize = stack.fittingSize
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        warning = popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak popover] in popover?.close() }
    }

    @objc private func dismissWarning() { warning?.close() }
    @objc private func openDisplaySettings() {
        warning?.close()
        let pane = NSScreen.screensHaveSeparateSpaces
            ? "com.apple.Displays-Settings.extension" : "com.apple.Desktop-Settings.extension"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }

    private func checkGestureSettings() {
        guard manager.options.config.gesture.enabled else { return }
        let conflicts = GestureConflict.checkLive(fingers: manager.options.config.gesture.fingers)
        if !conflicts.isEmpty {
            if !gestureWarningShown {
                gestureWarningShown = true
                showGestureWarning("Three-finger gestures are enabled in macOS System Settings, which conflicts with Paperi's trackpad swipe.\n\nDisable three-finger gestures in Trackpad Settings to use Paperi's swipe gesture.")
            }
        } else {
            gestureWarningShown = false
        }
    }

    private func showGestureWarning(_ text: String) {
        guard let button = item?.button else { return }
        warning?.close()
        let width: CGFloat = 300
        let title = NSTextField(wrappingLabelWithString: "Three-finger swipe disabled")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let body = NSTextField(wrappingLabelWithString: text)
        for label in [title, body] {
            label.preferredMaxLayoutWidth = width
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        let open = NSButton(title: "Open Trackpad Settings", target: self, action: #selector(openTrackpadSettings))
        open.bezelStyle = .rounded; open.keyEquivalent = "\r"
        let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissWarning))
        dismiss.bezelStyle = .rounded
        let buttons = NSStackView(views: [dismiss, open])
        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let controller = NSViewController()
        controller.view = stack
        stack.layoutSubtreeIfNeeded()
        controller.preferredContentSize = stack.fittingSize
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        warning = popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak popover] in popover?.close() }
    }

    @objc private func openTrackpadSettings() {
        warning?.close()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[paperi] \(message)\n".utf8))
    }

    @discardableResult private func dispatch(_ command: [String], source: String) -> [String: Any] {
        var reply: [String: Any]
        if command.first == "resume", let problem = arrangementPause {
            showWarning(problem)
            return ["ok": false, "paused": true, "error": problem]
        }
        switch command.first {
        case "reload": reply = reload()
        default: reply = manager.handle(command)
        }
        if reply["stop"] as? Bool == true {
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.shutdown(0) } }
        }
        if command.first == "status" {
            reply["hotkeys"] = hotkeyReport.registered
            reply["hotkeyFailures"] = hotkeyReport.failures
            reply["hotkeyConfigErrors"] = hotkeyReport.errors
        }
        if source == "hotkey" && (verbose || reply["ok"] as? Bool != true) {
            FileHandle.standardError.write(Data("[paperi] key → \(command.joined(separator: " ")): \(reply.filter { $0.key != "missionControl" })\n".utf8))
        }
        updateTitle()
        return reply
    }

    private func reload() -> [String: Any] {
        let config: LiveConfig
        do { config = try loadConfig() } catch { return ["ok": false, "error": "invalid config: \(error)"] }
        var reply = manager.reload(config)
        registerHotkeys()
        gestureWarningShown = false
        checkGestureSettings()
        reply["hotkeys"] = hotkeyReport.registered
        reply["hotkeyConfigErrors"] = hotkeyReport.errors
        return reply
    }

    private func shutdown(_ code: Int32) -> Never {
        keys?.unregister()
        server?.stop()
        Diagnostics.printJSON(manager.stop(), pretty: false)
        exit(code)
    }

    // MARK: menu bar

    private func installMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        BrandIcon.install(on: item?.button)
        item?.button?.toolTip = "Paperi"
        let menu = NSMenu()
        menu.delegate = self
        item?.menu = menu
    }

    private func updateTitle() {
        guard AXIsProcessTrusted() else { return }
        item?.button?.title = manager.paused ? " ⏸" : ""
        item?.button?.toolTip = arrangementPause.map { "Paperi paused: \(Self.pauseLabel($0))" } ?? "Paperi"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state: String
        if !AXIsProcessTrusted() { state = "Waiting for Accessibility access" }
        else if let reason = arrangementPause { state = "Paused (\(Self.pauseLabel(reason)))" }
        else if manager.paused { state = "Paused" }
        else { state = "Managing \(manager.managedWindowCount) window\(manager.managedWindowCount == 1 ? "" : "s")" }
        menu.addItem(withTitle: "Paperi — \(state)", action: nil, keyEquivalent: "")
        if hotkeysEnabled && manager.options.config.hotkeysEnabled {
            let detail = hotkeyReport.failures.isEmpty && hotkeyReport.errors.isEmpty
                ? "\(hotkeyReport.registered) shortcuts active"
                : "\(hotkeyReport.registered) shortcuts active, \(hotkeyReport.failures.count + hotkeyReport.errors.count) problem(s)"
            menu.addItem(withTitle: detail, action: nil, keyEquivalent: "")
        }
        add(menu, "Settings…", #selector(openSettings), key: ",")
        if let reason = arrangementPause, SkyLightHealth.isProblem(reason) {
            let why = menu.addItem(withTitle: "Space information unavailable (hover for details)", action: nil, keyEquivalent: "")
            why.toolTip = reason
        } else if let reason = arrangementPause {
            let why = menu.addItem(withTitle: "Update display settings to resume", action: nil, keyEquivalent: "")
            why.toolTip = reason
            add(menu, "Open Display Settings…", #selector(openDisplaySettings))
        }
        let gestureConflicts = GestureConflict.checkLive(fingers: manager.options.config.gesture.fingers)
        if manager.options.config.gesture.enabled && !gestureConflicts.isEmpty {
            let item = menu.addItem(withTitle: "Three-finger swipe disabled: system conflict", action: #selector(openTrackpadSettings), keyEquivalent: "")
            item.toolTip = gestureConflicts.joined(separator: "\n")
            add(menu, "Open Trackpad Settings…", #selector(openTrackpadSettings))
        }
        menu.addItem(.separator())
        if arrangementPause == nil { add(menu, manager.paused ? "Resume" : "Pause", #selector(togglePause)) }
        add(menu, "Reload Config", #selector(reloadConfig))
        add(menu, "Open Config…", #selector(openConfig))
        menu.addItem(.separator())
        if !AXIsProcessTrusted() { add(menu, "Open Accessibility Settings…", #selector(openAccessibility)) }
        menu.addItem(.separator())
        add(menu, "Stop & Restore Windows", #selector(stopAndQuit), key: "q")
    }

    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() { dispatch([manager.paused ? "resume" : "pause"], source: "menu") }
    @objc private func reloadConfig() {
        let reply = dispatch(["reload"], source: "menu")
        if reply["ok"] as? Bool != true || !(reply["hotkeyConfigErrors"] as? [String] ?? []).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Paperi config problem"
            alert.informativeText = ([reply["error"] as? String].compactMap { $0 } + (reply["hotkeyConfigErrors"] as? [String] ?? []))
                .joined(separator: "\n")
            NSApp.activate(); alert.runModal()
        }
    }
    @objc private func openSettings() {
        if settingsWindow?.window?.isVisible != true {
            settingsWindow = SettingsWindow(apply: { [weak self] in self?.reload() ?? ["ok": false] },
                                            openJSON: { [weak self] in self?.openConfig() })
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openConfig() {
        let url = LiveConfig.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(LiveConfig.template.utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func stopAndQuit() { shutdown(0) }
}

/// Per-user LaunchAgent that starts `paperi run` at login and restarts it if
/// it crashes (a crash restart first restores the stale journal).
enum LoginAgent {
    static let label = "dev.paperi.run"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var installedApp: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Paperi.app/Contents/MacOS/Paperi")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The installed app keeps one stable Accessibility grant across rebuilds
    /// of the repository; fall back to the running binary.
    static var executable: String {
        if FileManager.default.isExecutableFile(atPath: installedApp.path) { return installedApp.path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func command(_ args: [String]) -> [String: Any] {
        switch args.first {
        case "on": return enable()
        case "off": return disable()
        case "status", nil:
            return ["ok": true, "enabled": isEnabled, "plist": plistURL.path,
                    "program": (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first ?? NSNull()]
        default: return ["ok": false, "error": "usage: paperi login on|off|status"]
        }
    }

    static func enable() -> [String: Any] {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Paperi.log").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": logs, "StandardErrorPath": logs,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch { return ["ok": false, "error": "\(error)"] }
        // Takes effect at next login; never starts or kills an instance now.
        return ["ok": true, "enabled": true, "program": executable, "plist": plistURL.path, "log": logs,
                "note": "Starts at next login; `launchctl bootstrap gui/\(getuid()) \(plistURL.path)` starts it now"]
    }

    /// Removing the plist prevents the next login start without stopping the
    /// instance that is running now.
    static func disable() -> [String: Any] {
        try? FileManager.default.removeItem(at: plistURL)
        return ["ok": true, "enabled": false]
    }
}
