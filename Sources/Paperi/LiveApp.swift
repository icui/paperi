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
        guard hotkeysEnabled else { keys.unregister(); hotkeyReport = (0, [:], []); hotkeyBindings = []; return }
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
        item?.button?.title = "▥"
        item?.button?.toolTip = "Paperi"
        let menu = NSMenu()
        menu.delegate = self
        item?.menu = menu
    }

    private func updateTitle() {
        guard AXIsProcessTrusted() else { return }
        item?.button?.title = manager.paused ? "▥ ⏸" : "▥"
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
        if hotkeysEnabled {
            let detail = hotkeyReport.failures.isEmpty && hotkeyReport.errors.isEmpty
                ? "\(hotkeyReport.registered) shortcuts active"
                : "\(hotkeyReport.registered) shortcuts active, \(hotkeyReport.failures.count + hotkeyReport.errors.count) problem(s)"
            menu.addItem(withTitle: detail, action: nil, keyEquivalent: "")
            if !hotkeyBindings.isEmpty {
                let shortcuts = menu.addItem(withTitle: "Show Shortcuts", action: nil, keyEquivalent: "")
                shortcuts.submenu = shortcutsMenu()
            }
        }
        let config = menu.addItem(withTitle: "Show Config", action: nil, keyEquivalent: "")
        config.submenu = configMenu()
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

    /// One row per resolved binding (defaults merged with config overrides),
    /// with the shortcut drawn natively on the right; choosing a row runs it.
    private func shortcutsMenu() -> NSMenu {
        let menu = NSMenu()
        for binding in hotkeyBindings {
            let failed = hotkeyReport.failures[binding.display] != nil
            let title = binding.command.joined(separator: " ") + (failed ? " (unavailable)" : "")
            let item = NSMenuItem(title: title, action: #selector(runShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = binding.command
            if let (key, mask) = Self.menuKeyEquivalent(binding.spec) {
                item.keyEquivalent = key; item.keyEquivalentModifierMask = mask
            } else {
                item.title = "\(binding.display)  \(title)"
            }
            menu.addItem(item)
        }
        for error in hotkeyReport.errors {
            if menu.items.count == hotkeyBindings.count { menu.addItem(.separator()) }
            menu.addItem(withTitle: "⚠︎ \(error)", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        add(menu, "Edit in Config…", #selector(openConfig))
        return menu
    }

    /// Every setting with the value in effect (config merged with CLI flags and
    /// built-in defaults). Choosing a value row copies it to the clipboard.
    private func configMenu() -> NSMenu {
        let menu = NSMenu()
        let config = manager.options.config
        let url = LiveConfig.defaultURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        let file = add(menu, exists ? url.path : "No config file — using defaults", #selector(openConfig))
        file.toolTip = "Open \(url.path)"
        menu.addItem(.separator())

        func number(_ value: Double) -> String { value.rounded() == value ? "\(Int(value)) pt" : "\(value) pt" }
        func origin(_ isSet: Bool) -> String { isSet ? "" : "  (default)" }
        value(menu, "Gap: \(number(manager.options.gap))\(origin(config.gap != nil))", copy: "\(manager.options.gap)",
              tip: "\"gap\": space between columns and between stacked windows")
        value(menu, "Outer gap: \(number(manager.options.outerGap))\(origin(config.outerGap != nil))",
              copy: "\(manager.options.outerGap)", tip: "\"outerGap\": inset from the screen edges")
        let color = config.swapHighlight ?? LiveConfig.defaultSwapHighlight
        let swatch = value(menu, "Swap highlight: \(color)\(origin(config.swapHighlight != nil))", copy: color,
                           tip: "\"swapHighlight\": mask over the window a drag would swap with, #RRGGBB[AA]")
        swatch.image = Self.swatch(config.swapHighlightColor)
        let scroll = config.focusScrollDuration ?? 0.22
        value(menu, "Focus scroll duration: \(scroll == 0 ? "off (immediate)" : "\(scroll) s")\(origin(config.focusScrollDuration != nil))",
              copy: "\(scroll)", tip: "\"focusScrollDuration\": seconds from 0 to 1 for focus scrolls and swipe landings; 0 disables")
        value(menu, "Focus after close: \(config.focusAfterClose.rawValue)\(origin(config.focusAfterClose != .left))",
              copy: config.focusAfterClose.rawValue,
              tip: "\"focusAfterClose\": left, right or system — where focus goes when the focused column closes")
        menu.addItem(.separator())

        let cliApps = Set(cliInclude), cliSingles = Set(cliSingletons)
        if let include = config.include {
            list(menu, "Managed apps: only \(include.count)", include.map { appLabel($0) + (cliApps.contains($0) ? "  (--app)" : "") },
                 tip: "\"include\" / --app: only these apps are tiled")
        } else {
            value(menu, "Managed apps: all regular apps", copy: nil, tip: "Add \"include\" to limit tiling to named apps")
        }
        let builtIn = LiveConfig.defaultExclude.subtracting(config.exclude).sorted()
        list(menu, "Excluded apps: \(config.exclude.count) + \(builtIn.count) built-in",
             config.exclude.map(appLabel) + (builtIn.isEmpty ? [] : ["—"] + builtIn.map { appLabel($0) + "  (built-in)" }),
             tip: "\"exclude\": apps never tiled")
        list(menu, "Apps without native tabs: \(config.singleton.count)",
             config.singleton.map { appLabel($0) + (cliSingles.contains($0) ? "  (--singleton-app)" : "") },
             tip: "\"singleton\": apps whose tab bars are drawn in-content")
        list(menu, "Float rules: \(config.float.count)", config.float.map(ruleLabel),
             tip: "\"float\": windows managed for focus but never tiled")
        list(menu, "Tile rules: \(config.tile.count)", config.tile.map(ruleLabel),
             tip: "\"tile\": utility-looking windows that are tiled anyway")
        menu.addItem(.separator())

        if hotkeysEnabled {
            let custom = config.hotkeys.count
            value(menu, "Shortcuts: \(hotkeyBindings.count) active, \(custom) set in config", copy: nil,
                  tip: "\"hotkeys\": key spec → command; null removes a default")
        } else {
            value(menu, "Shortcuts: off (--no-hotkeys)", copy: nil, tip: nil)
        }
        gestureRows(menu, config.gesture)
        value(menu, "Restore windows on stop: \(manager.options.restoreOnStop ? "on" : "off (--no-restore)")", copy: nil, tip: nil)
        value(menu, "Verbose logging: \(verbose ? "on (--verbose)" : "off")", copy: nil, tip: nil)
        menu.addItem(.separator())
        add(menu, exists ? "Edit Config…" : "Create Config…", #selector(openConfig))
        add(menu, "Reload Config", #selector(reloadConfig))
        return menu
    }

    /// The "gesture" object: a summary row with every field in its submenu.
    private func gestureRows(_ menu: NSMenu, _ gesture: LiveConfig.GestureConfig) {
        let defaults = LiveConfig.GestureConfig()
        func origin(_ isDefault: Bool) -> String { isDefault ? "  (default)" : "" }
        let summary = gesture.enabled ? "\(gesture.fingers) fingers" + (gesture.invert ? ", inverted" : "") : "off"
        let item = menu.addItem(withTitle: "Trackpad swipe: \(summary)", action: nil, keyEquivalent: "")
        item.toolTip = "\"gesture\": horizontal swipe that scrolls the strip by one column"
        let sub = NSMenu()
        value(sub, "Enabled: \(gesture.enabled ? "on" : "off")\(origin(gesture.enabled == defaults.enabled))",
              copy: "\(gesture.enabled)", tip: "\"gesture.enabled\"")
        value(sub, "Fingers: \(gesture.fingers)\(origin(gesture.fingers == defaults.fingers))",
              copy: "\(gesture.fingers)", tip: "\"gesture.fingers\": 3 or 4")
        value(sub, "Travel: \(gesture.travel)\(origin(gesture.travel == defaults.travel))", copy: "\(gesture.travel)",
              tip: "\"gesture.travel\": fraction of the trackpad width for one column, in (0, 1]")
        value(sub, "Commit threshold: \(gesture.commitThreshold)\(origin(gesture.commitThreshold == defaults.commitThreshold))",
              copy: "\(gesture.commitThreshold)",
              tip: "\"gesture.commitThreshold\": fraction of a column past which release moves, in (0, 1]")
        value(sub, "Flick velocity: \(gesture.flickVelocity)\(origin(gesture.flickVelocity == defaults.flickVelocity))",
              copy: "\(gesture.flickVelocity)", tip: "\"gesture.flickVelocity\": release speed that moves regardless of distance")
        value(sub, "Invert: \(gesture.invert ? "on" : "off")\(origin(gesture.invert == defaults.invert))",
              copy: "\(gesture.invert)", tip: "\"gesture.invert\": reverse the swipe direction")
        value(sub, "Swipe up to close: \(gesture.swipeUpToClose ? "on" : "off")\(origin(gesture.swipeUpToClose == defaults.swipeUpToClose))",
              copy: "\(gesture.swipeUpToClose)", tip: "\"gesture.swipeUpToClose\": swiping up closes the focused window")
        let apps = gesture.tabCloseApps.isEmpty ? "none" : gesture.tabCloseApps.joined(separator: ", ")
        value(sub, "Tab close apps: \(apps)\(origin(gesture.tabCloseApps == defaults.tabCloseApps))",
              copy: gesture.tabCloseApps.joined(separator: ", "),
              tip: "\"gesture.tabCloseApps\": bundle IDs whose swipe up closes the current tab with ⌘W")
        item.submenu = sub
    }

    @discardableResult private func value(_ menu: NSMenu, _ title: String, copy: String?, tip: String?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: copy == nil ? nil : #selector(copyValue(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = copy
        item.toolTip = tip.map { $0 + (copy == nil ? "" : " — click to copy") }
        return item
    }

    private func list(_ menu: NSMenu, _ title: String, _ rows: [String], tip: String) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.toolTip = tip
        let sub = NSMenu()
        if rows.isEmpty { sub.addItem(withTitle: "None", action: nil, keyEquivalent: "") }
        for row in rows {
            if row == "—" { sub.addItem(.separator()); continue }
            value(sub, row, copy: row.components(separatedBy: "  (").first, tip: nil)
        }
        item.submenu = sub
    }

    /// "Safari (com.apple.Safari)" when the app is installed, else the bundle ID.
    private func appLabel(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return "\(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")) (\(bundleID))"
    }

    private func ruleLabel(_ rule: LiveConfig.FloatRule) -> String {
        guard let needle = rule.titleContains, !needle.isEmpty else { return appLabel(rule.app) + " — all windows" }
        return appLabel(rule.app) + " — title contains \"\(needle)\""
    }

    /// Colour sample over a checkerboard so the alpha is visible.
    private static func swatch(_ color: HexColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            path.addClip()
            NSColor.white.setFill(); rect.fill()
            NSColor.lightGray.setFill()
            for x in 0..<2 { for y in 0..<2 where (x + y) % 2 == 0 {
                NSRect(x: CGFloat(x) * 7, y: CGFloat(y) * 7, width: 7, height: 7).fill()
            } }
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setFill()
            rect.fill(using: .sourceOver)
            NSColor.separatorColor.setStroke(); path.stroke()
            return true
        }
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Maps a spec like "alt-cmd-left" to an NSMenuItem key equivalent, or nil
    /// when the key has no single-character form (the row then shows the spec).
    private static func menuKeyEquivalent(_ spec: String) -> (String, NSEvent.ModifierFlags)? {
        let parts = spec.split(separator: "-").map(String.init)
        guard let key = parts.last else { return nil }
        var mask: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd": mask.insert(.command)
            case "alt": mask.insert(.option)
            case "ctrl": mask.insert(.control)
            case "shift": mask.insert(.shift)
            default: return nil
            }
        }
        func scalar(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }
        let named: [String: String] = [
            "left": scalar(NSLeftArrowFunctionKey), "right": scalar(NSRightArrowFunctionKey),
            "up": scalar(NSUpArrowFunctionKey), "down": scalar(NSDownArrowFunctionKey),
            "space": " ", "return": "\r", "enter": "\r", "tab": "\t", "escape": "\u{1b}",
            "delete": "\u{8}", "forwarddelete": scalar(NSDeleteFunctionKey),
            "home": scalar(NSHomeFunctionKey), "end": scalar(NSEndFunctionKey),
            "pageup": scalar(NSPageUpFunctionKey), "pagedown": scalar(NSPageDownFunctionKey),
            "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
            "semicolon": ";", "quote": "'", "grave": "`", "leftbracket": "[", "rightbracket": "]",
        ]
        if let k = named[key] { return (k, mask) }
        if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...20).contains(n) {
            return (scalar(NSF1FunctionKey + n - 1), mask)
        }
        if key.count == 1 { return (key, mask) }
        return nil
    }

    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? [String] else { return }
        dispatch(command, source: "menu")
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
