import AppKit
@preconcurrency import ApplicationServices
import PaperiCore
import PaperiPlatform

var args = Array(CommandLine.arguments.dropFirst())
// Launching Paperi.app (Finder, login item) starts live mode.
if args.isEmpty && Bundle.main.bundleURL.pathExtension == "app" { args = ["run"] }
switch args.first {
case "run":
    LiveApp.main(Array(args.dropFirst()))
case "msg":
    do {
        let reply = try LiveCommandServer.send(Array(args.dropFirst()))
        FileHandle.standardOutput.write(reply)
        let ok = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["ok"] as? Bool ?? false
        exit(ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("paperi msg: \(error)\n".utf8)); exit(1)
    }
case "check-apps":
    guard AXIsProcessTrusted() else { print("Accessibility access is required."); exit(1) }
    Diagnostics.printJSON(LiveManager.checkApps(Array(args.dropFirst()), config: (try? LiveConfig.load()) ?? LiveConfig()))
case "login":
    let report = LoginAgent.command(Array(args.dropFirst()))
    Diagnostics.printJSON(report)
    exit(report["ok"] as? Bool == true ? 0 : 1)
case "restore":
    guard AXIsProcessTrusted() else { print("Accessibility access is required."); exit(1) }
    Diagnostics.printJSON(LiveManager.restore())
case "mission-control-move":
    var rest = args.filter { $0 != "--escape" }
    var exitClick: UInt32?
    if let i = rest.firstIndex(of: "--exit-click"), rest.indices.contains(i + 1) {
        exitClick = UInt32(rest[i + 1]); rest.removeSubrange(i...(i + 1))
    }
    guard rest.count == 3, let wid = UInt32(rest[1]), let space = UInt64(rest[2]) else {
        print("Usage: paperi mission-control-move windowID spaceID [--escape | --exit-click windowID]"); exit(2)
    }
    let report = Diagnostics.missionControlMove(windowID: wid, toSpace: space, exitWithEscape: args.contains("--escape"),
                                                exitClicking: exitClick)
    Diagnostics.printJSON(report)
    exit(report["transferred"] as? Bool == true ? 0 : 1)
case "probe-terminal-session":
    guard args.count == 2 else { print("Usage: paperi probe-terminal-session testTag"); exit(2) }
    let report = Diagnostics.probeTerminalSession(tag: args[1])
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "probe-terminal-placement", "probe-terminal-resize":
    guard args.count == 3, let id = UInt32(args[1]) else { print("Usage: paperi probe-terminal-placement | probe-terminal-resize windowID testTag"); exit(2) }
    let report = Diagnostics.probeTerminalPlacement(windowID: id, tag: args[2], resize: args.first == "probe-terminal-resize")
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "probe-native-tab-session", "probe-native-tab-lifecycle", "probe-native-tab-growth":
    guard args.count == 1 else { print("Usage: paperi probe-native-tab-session | probe-native-tab-lifecycle | probe-native-tab-growth"); exit(2) }
    let report = Diagnostics.probeNativeTabSession(reconcileTopology: args.first != "probe-native-tab-session",
        admitNewMembers: args.first == "probe-native-tab-growth")
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "preview-fixture", "probe-preview-input":
    guard args.count == 1 else { print("Usage: paperi preview-fixture | probe-preview-input"); exit(2) }
    let report = Diagnostics.probeLifecycle(preview: true, automatedPreview: args.first == "probe-preview-input")
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "probe-stop":
    guard args.count == 1 else { print("Usage: paperi probe-stop"); exit(2) }
    let report = Diagnostics.probeLifecycle(stopWhileOpen: true)
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "probe-interaction":
    guard args.count == 1 else { print("Usage: paperi probe-interaction"); exit(2) }
    let report = Diagnostics.probeLifecycle(interaction: true)
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "probe-resize":
    guard args.count == 1 else { print("Usage: paperi probe-resize"); exit(2) }
    let report = Diagnostics.probeLifecycle(externalResize: true)
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "probe-lifecycle":
    guard args.count == 1 else { print("Usage: paperi probe-lifecycle"); exit(2) }
    let report = Diagnostics.probeLifecycle()
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "probe-placement":
    guard args.count == 1 else { print("Usage: paperi probe-placement"); exit(2) }
    let report = Diagnostics.probePlacement()
    Diagnostics.printJSON(report)
    exit(report["result"] as? String == "passed" ? 0 : 1)
case "snapshot":
    Diagnostics.printJSON(Diagnostics.snapshot(includeTitles: args.contains("--include-titles")))
case "tab-evidence":
    guard args.count == 2, !args[1].isEmpty else { print("Usage: paperi tab-evidence bundle.identifier"); exit(2) }
    Diagnostics.printJSON(Diagnostics.tabEvidence(bundleID: args[1]))
case "window-evidence":
    guard args.count == 2, !args[1].isEmpty else { print("Usage: paperi window-evidence bundle.identifier"); exit(2) }
    Diagnostics.printJSON(Diagnostics.windowEvidence(bundleID: args[1]))
case "record":
    guard let options = try? RecordingOptions(arguments: Array(args.dropFirst())) else {
        print("Usage: paperi record [seconds: >0 and <=300] [--bundle-id identifier ...] [--tab-evidence] [--window-evidence] [--restart-after seconds] [--reconcile-every 1..30] [--poll-only (requires reconciliation)] (evidence/reconciliation requires one bundle)")
        exit(2)
    }
    guard AXIsProcessTrusted() else { print("Accessibility access is required. Run the app and select Request Accessibility Access."); exit(1) }
    Diagnostics.printJSON(["event": "recordingStarted", "durationSeconds": options.seconds], pretty: false)
    let recorder = EventRecorder(bundleIDs: options.bundleIDs, observeWorkspaceEvents: !options.pollOnly)
    recorder.start()
    let reconcileTimer = options.reconcileEvery.map { interval in
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { recorder.reconcileNow() }
        }
    }
    let restartTimer = options.restartAfter.map { delay in
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                let teardown = recorder.stop()
                recorder.start()
                Diagnostics.printJSON(["event": "recorderRestarted", "teardown": teardown,
                                       "uptime": ProcessInfo.processInfo.systemUptime], pretty: false)
            }
        }
    }
    var evidenceTimer: Timer?
    if options.includeTabEvidence || options.includeWindowEvidence, let bundleID = options.bundleIDs?.first {
        evidenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if options.includeTabEvidence {
                    let started = ProcessInfo.processInfo.systemUptime
                    var evidence = recorder.tabEvidence(bundleID: bundleID)
                    evidence["event"] = "tabEvidence"
                    evidence["captureStartedUptime"] = started
                    evidence["uptime"] = ProcessInfo.processInfo.systemUptime
                    Diagnostics.printJSON(evidence, pretty: false)
                }
                if options.includeWindowEvidence {
                    let started = ProcessInfo.processInfo.systemUptime
                    var evidence = recorder.windowEvidence(bundleID: bundleID)
                    evidence["event"] = "windowEvidence"
                    evidence["captureStartedUptime"] = started
                    evidence["uptime"] = ProcessInfo.processInfo.systemUptime
                    Diagnostics.printJSON(evidence, pretty: false)
                }
            }
        }
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: options.seconds))
    evidenceTimer?.invalidate()
    reconcileTimer?.invalidate()
    restartTimer?.invalidate()
    let teardown = recorder.stop()
    Diagnostics.printJSON(["event": "recordingEnded", "teardown": teardown], pretty: false)
case "benchmark-core":
    let canvas = Rect(x: 0, y: 0, width: 1440, height: 900)
    var samples: [Double] = []
    let layout = Layout(columns: (1...50).map { Column(slots: [Slot(id: "\($0)", members: [UInt32($0)], activeMember: UInt32($0))], width: 600) })
    var checksum = 0.0
    for _ in 0..<1000 {
        let start = ProcessInfo.processInfo.systemUptime
        for placement in try layout.placements(in: canvas) { checksum += placement.frame.x }
        samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    samples.sort()
    Diagnostics.printJSON(["windows": 50, "iterations": samples.count, "p50MS": samples[500], "p95MS": samples[950],
        "checksum": checksum, "scope": "cached pure core only; excludes AX, rendering and input latency"])
case "help", "--help", "-h":
    let topic = args.count > 1 ? args[1] : nil
    guard args.count <= 2, topic == nil || topic == "diagnostics" || topic == "developer" else {
        print("Usage: paperi help [diagnostics|developer]")
        exit(2)
    }
    printHelp(topic)
default:
    if let command = args.first {
        FileHandle.standardError.write(Data("Unknown command: \(command)\nUse paperi help to see available commands.\n".utf8))
        exit(2)
    }
    printHelp()
}

func printHelp(_ topic: String? = nil) {
    switch topic {
    case "diagnostics":
        print("""
        Paperi diagnostics
          paperi check-apps [ID ...]          Explain management decisions for on-screen windows
          paperi snapshot [--include-titles] Read-only JSON snapshot
          paperi tab-evidence identifier     Bounded AX tab structure for one app
          paperi window-evidence identifier  Window policy and focus metadata for one app
          paperi record [seconds] [--bundle-id identifier ...] [--tab-evidence] [--window-evidence]
                        [--restart-after seconds] [--reconcile-every 1..30] [--poll-only]
                                             Read-only AX event JSONL (default 30 seconds, max 300)
          paperi msg status                  Running manager state

        paperi help                            Everyday commands
        paperi help developer                  Integration probes and development tools
        """)
    case "developer":
        print("""
        Paperi developer tools
          paperi benchmark-core              Cached layout timing; excludes AX, rendering and input
          paperi msg swipe left|right|up|down [travel]
                                             Simulate a window animation, not configured gesture commands
          paperi preview-fixture             Interactive disposable preview (60-second limit)
          paperi probe-preview-input         Validate the preview's AppKit input
          paperi probe-placement             Place and restore a disposable window
          paperi probe-lifecycle             Create, tile and close disposable windows
          paperi probe-resize                Adopt a fixture-originated resize
          paperi probe-interaction           Check resize commands and panel suppression
          paperi probe-stop                  Check restoration and rejection of stale work
          paperi probe-native-tab-session    Check native-tab selection and placement
          paperi probe-native-tab-lifecycle  Check native-tab detach, merge and closure
          paperi probe-native-tab-growth     Check native-tab creation and admission
          paperi probe-terminal-session TAG  Check a tagged Terminal tab session
          paperi probe-terminal-placement ID TAG
                                             Translate and restore a tagged Terminal window
          paperi probe-terminal-resize ID TAG
                                             Resize and restore a tagged Terminal window
          paperi mission-control-move WID SPACE [--escape | --exit-click WID]
                                             Move a real window between Spaces for integration testing

        paperi help                            Everyday commands
        paperi help diagnostics                Read-only troubleshooting tools
        """)
    default:
        print("""
        Paperi — window management
          paperi run [--app ID ...] [--singleton-app ID ...] [-v] [--no-restore] [--no-hotkeys]
                                             Manage windows on each display's active Space
          paperi msg COMMAND                 Send a command to the running manager:
            focus left|right|up|down         Focus a neighboring window
            swap left|right|up|down          Swap the focused window with a neighbor
            width|height +|- [fraction]      Resize the focused column or stacked window
            center                          Center the focused column
            align left|right|center         Align the focused column within the usable screen
            split [left|right]              Split with left or right (default: left)
            slurp                           Stack the focused window in the left column
            barf                            Move a window out of the stack
            float                           Toggle the focused window's floating state
            tray                            Show the window tray
            retile                          Reapply the layout
            status                          Show manager state
            pause|resume                    Pause or resume management
            reload                          Reload configuration
            stop                            Stop management
          paperi login on|off|status          Configure start at login
          paperi restore                     Restore frames after an unclean stop

          paperi help diagnostics            Read-only troubleshooting tools
          paperi help developer              Integration probes and development tools
        """)
    }
}
