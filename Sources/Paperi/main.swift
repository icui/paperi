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
case "record":
    let seconds = args.count > 1 ? Double(args[1]) ?? 0 : 30
    guard seconds > 0, seconds <= 300 else { print("Duration must be between 0 and 300 seconds"); exit(2) }
    guard AXIsProcessTrusted() else { print("Accessibility access is required. Run the app and select Request Accessibility Access."); exit(1) }
    Diagnostics.printJSON(["event": "recordingStarted", "durationSeconds": seconds], pretty: false)
    let recorder = EventRecorder(); recorder.start()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    recorder.stop()
    Diagnostics.printJSON(["event": "recordingEnded"], pretty: false)
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
      paperi record [seconds]            Read-only AX event JSONL (default 30, max 300)
      paperi benchmark-core              Measure cached layout calculation only
      paperi --menu                      Run diagnostic menu bar shell
    """)
}
