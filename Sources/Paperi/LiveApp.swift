import AppKit
@preconcurrency import ApplicationServices
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
        item?.button?.title = "▥ ⚠︎"
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustTimer?.invalidate(); self.trustTimer = nil
                self.startManaging()
            }
        }
    }

    private func startManaging() {
        do { try manager.start() } catch {
            FileHandle.standardError.write(Data("paperi run: \(error)\n".utf8)); shutdown(1)
        }
        registerHotkeys()
        item?.button?.title = "▥"
        Diagnostics.printJSON(["event": "paperiRunning",
                               "apps": manager.options.config.include?.sorted() ?? ["all regular apps"],
                               "socket": LiveCommandServer.defaultPath, "hotkeys": hotkeyReport.registered,
                               "hotkeyFailures": hotkeyReport.failures, "hotkeyConfigErrors": hotkeyReport.errors], pretty: false)
    }

    private func registerHotkeys() {
        guard hotkeysEnabled else { keys.unregister(); hotkeyReport = (0, [:], []); return }
        let resolved = HotKeyBindings.resolve(overrides: manager.options.config.hotkeys)
        let failures = keys.register(resolved.bindings)
        hotkeyReport = (keys.registeredCount, failures, resolved.errors)
        for error in resolved.errors { FileHandle.standardError.write(Data("[paperi] config: \(error)\n".utf8)) }
        for (key, status) in failures.sorted(by: { $0.key < $1.key }) {
            FileHandle.standardError.write(Data("[paperi] \(key) unavailable (OSStatus \(status)); held by another app?\n".utf8))
        }
    }

    @discardableResult private func dispatch(_ command: [String], source: String) -> [String: Any] {
        var reply: [String: Any]
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
        item?.button?.title = "▥"
        item?.button?.toolTip = "Paperi"
        let menu = NSMenu()
        menu.delegate = self
        item?.menu = menu
    }

    private func updateTitle() {
        guard AXIsProcessTrusted() else { return }
        item?.button?.title = manager.paused ? "▥ ⏸" : "▥"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state: String
        if !AXIsProcessTrusted() { state = "Waiting for Accessibility access" }
        else if manager.paused { state = "Paused" }
        else { state = "Managing \(manager.managedWindowCount) window\(manager.managedWindowCount == 1 ? "" : "s")" }
        menu.addItem(withTitle: "Paperi — \(state)", action: nil, keyEquivalent: "")
        if hotkeysEnabled {
            let detail = hotkeyReport.failures.isEmpty && hotkeyReport.errors.isEmpty
                ? "\(hotkeyReport.registered) shortcuts active"
                : "\(hotkeyReport.registered) shortcuts active, \(hotkeyReport.failures.count + hotkeyReport.errors.count) problem(s)"
            menu.addItem(withTitle: detail, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        add(menu, manager.paused ? "Resume" : "Pause", #selector(togglePause))
        add(menu, "Retile", #selector(retile))
        add(menu, "Reload Config", #selector(reloadConfig))
        add(menu, "Open Config…", #selector(openConfig))
        menu.addItem(.separator())
        let login = add(menu, "Start at Login", #selector(toggleLogin))
        login.state = LoginAgent.isEnabled ? .on : .off
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
    @objc private func retile() { dispatch(["retile"], source: "menu") }
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
    @objc private func openConfig() {
        let url = LiveConfig.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(LiveConfig.template.utf8).write(to: url)
        }
        NSWorkspace.shared.open(url)
    }
    @objc private func toggleLogin() {
        let report = LoginAgent.command([LoginAgent.isEnabled ? "off" : "on"])
        if report["ok"] as? Bool != true {
            let alert = NSAlert()
            alert.messageText = "Could not change Start at Login"
            alert.informativeText = report["error"] as? String ?? ""
            NSApp.activate(); alert.runModal()
        }
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
