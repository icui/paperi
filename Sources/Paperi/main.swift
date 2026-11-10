import AppKit
@preconcurrency import ApplicationServices
import PaperiCore
import PaperiPlatform

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.title = "Paperi"
        let menu = NSMenu()
        menu.addItem(withTitle: "Feasibility build — management inactive", action: nil, keyEquivalent: "")
        let access = menu.addItem(withTitle: "Request Accessibility Access…", action: #selector(requestAccess), keyEquivalent: "")
        access.target = self
        let snapshot = menu.addItem(withTitle: "Print Diagnostic Snapshot", action: #selector(capture), keyEquivalent: "")
        snapshot.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Paperi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item?.menu = menu
    }
    @objc func capture() { Diagnostics.printJSON(Diagnostics.snapshot()) }
    @objc func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

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
    guard args.count == 3, let wid = UInt32(args[1]), let space = UInt64(args[2]) else {
        print("Usage: paperi mission-control-move windowID spaceID"); exit(2)
    }
    let report = Diagnostics.missionControlMove(windowID: wid, toSpace: space)
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
case "--menu":
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
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
default:
    print("""
    Paperi (opt-in live management; Option–Command shortcuts from the PaperWM config)
      paperi run [--app ID ...] [--singleton-app ID ...] [-v] [--no-restore] [--no-hotkeys]
                                        Manage all regular apps (or only --app ones) on each display's active Space
      paperi msg COMMAND                 focus|swap left|right|up|down, width|height +|- [fraction],
                                        center, split, slurp, barf, float, retile, status,
                                        pause, resume, reload, stop
      paperi check-apps [ID ...]         Read-only: what live mode would decide for each on-screen window
      paperi login on|off|status         Start live mode at login (LaunchAgent; prefers ~/Applications/Paperi.app)
      paperi restore                     Restore frames journaled by a run that did not stop cleanly
      paperi snapshot [--include-titles]  Read-only JSON snapshot
      paperi tab-evidence identifier     Bounded read-only AX tab structure for one app
      paperi probe-native-tab-session    Native-tab effects on a disposable child only
      paperi probe-native-tab-lifecycle  Disposable native detach/merge/closure effects
      paperi probe-native-tab-growth     Disposable native tab creation and admission
      paperi probe-terminal-placement ID TAG  Guarded tagged Terminal translation/recovery
      paperi probe-terminal-resize ID TAG     Guarded tagged Terminal cell-grid resize/recovery
      paperi window-evidence identifier  Bounded read-only window policy/focus metadata for one app
      paperi record [seconds] [--bundle-id identifier ...] [--tab-evidence] [--window-evidence] [--restart-after seconds] [--reconcile-every 1..30] [--poll-only]
                                        Read-only AX event JSONL (default 30, max 300)
      paperi benchmark-core              Measure cached layout calculation only
      paperi probe-placement             Move/resize only a newly launched disposable fixture, then restore
      paperi probe-lifecycle             Observe/reduce/tile two new disposable windows through create/close
      paperi probe-resize                Adopt a fixture-originated resize while tracking expected AX echoes
      paperi probe-interaction           Exercise focused resize commands, panel suppression and recovery on a new fixture
      paperi probe-stop                  Stop with two live fixture windows, restore original frames and reject stale work
      paperi mission-control-move WID SPACE Drag a real window onto a Space in Mission Control (any display)
      paperi preview-fixture             Interactive disposable preview; local controls, Stop & Restore, 60-second limit
      paperi probe-preview-input         Test AppKit key-equivalent/button input on the disposable preview
      paperi --menu                      Run diagnostic menu bar shell
    """)
}
