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
if args.isEmpty && Bundle.main.bundleURL.pathExtension == "app" { args = ["--menu"] }
switch args.first {
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
        print("Usage: paperi record [seconds: >0 and <=300] [--bundle-id identifier ...] [--tab-evidence] [--window-evidence] [--restart-after seconds] (evidence requires one bundle)")
        exit(2)
    }
    guard AXIsProcessTrusted() else { print("Accessibility access is required. Run the app and select Request Accessibility Access."); exit(1) }
    Diagnostics.printJSON(["event": "recordingStarted", "durationSeconds": options.seconds], pretty: false)
    let recorder = EventRecorder(bundleIDs: options.bundleIDs)
    recorder.start()
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
    Paperi feasibility build (window management is inactive)
      paperi snapshot [--include-titles]  Read-only JSON snapshot
      paperi tab-evidence identifier     Bounded read-only AX tab structure for one app
      paperi window-evidence identifier  Bounded read-only window policy/focus metadata for one app
      paperi record [seconds] [--bundle-id identifier ...] [--tab-evidence] [--window-evidence] [--restart-after seconds]
                                        Read-only AX event JSONL (default 30, max 300)
      paperi benchmark-core              Measure cached layout calculation only
      paperi --menu                      Run diagnostic menu bar shell
    """)
}
