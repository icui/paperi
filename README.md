# Paperi

Standalone macOS scrolling window manager in development. See [PLAN.md](PLAN.md) for the intended behavior and release gates.

The current implementation provides a pure Swift layout core (including resize, split, and floating transitions), regression tests, read-only native diagnostics, and an inactive menu bar shell. **It does not yet manage windows.** Native tabs, Space transfers, full keyboard parity, and trackpad capture remain feasibility work.

## Development

Requires macOS 14+ and Swift 6+ (Xcode or Command Line Tools). The initial host is macOS 26.7.2 on arm64; older releases are not validated. There are no third-party package dependencies. The Swift wrapper isolates a stale-private-manifest-interface issue found in this host's Command Line Tools and loads its bundled Swift Testing plugin explicitly; it never changes the installed toolchain.

```sh
./scripts/swift.sh build
./scripts/swift.sh test
./scripts/swift.sh run -c release paperi benchmark-core
./scripts/swift.sh run paperi snapshot
./scripts/swift.sh run paperi record 30 > captures/session.jsonl
./scripts/swift.sh run paperi record 30 --bundle-id com.apple.finder > captures/finder.jsonl
```

When running through a restricted coding-agent sandbox, an active-developer-directory or toolchain-access failure can reflect sandbox restrictions even when Command Line Tools are installed. Retry the same build/test command with approved access outside the sandbox before changing the system developer directory or installing another toolchain. The full debug build and 26 core regressions have passed this way; see [validation results](docs/STATUS.md#validation-on-the-initial-host).

Create `captures/` before redirecting; captures are ignored by Git. Snapshot and event recording never reposition or focus windows or register management shortcuts, so they can be used alongside Hammerspoon. Titles are omitted unless `snapshot --include-titles` is explicitly requested. IDs, bundle identifiers and geometry can still reveal activity; review captures before sharing.

Accessibility access is needed to enumerate and observe application windows. Without it, snapshots still report available display/Space information. No automatic permission prompt is shown by CLI diagnostics. Build the app and launch its menu to request access:

```sh
./scripts/build-app.sh
open dist/Paperi.app
```

The menu bar app is diagnostic-only. Developer signing is ad hoc by default; set `PAPERI_SIGN_IDENTITY` to a signing identity for a stable signed build. Ad hoc rebuilding may require renewing Accessibility access. No notarization or distribution setup is included yet.

Snapshots include raw AppKit display coordinates and AX window coordinates with explicit field names; they are not interchangeable. Optional private SkyLight/AX functions are dynamically resolved, and unavailable values are reported rather than guessed. A successful Space query is not proof that Space transfer is supported.

Event recording observes existing apps/windows, follows app launch/termination, and subscribes windows reported by creation or focus notifications. It reports `subscriptionFailed` records with PID, notification name, and AX error code rather than silently implying full coverage. `recorderReady` marks the end of initial subscription setup; the requested recording interval starts after setup, so total runtime can be longer. Observer/window-reference counts describe attempted coverage, not successful delivery. Applications can reject notifications or be unready at launch; retry coverage is bounded to three startup passes. `AXTabs` is captured in snapshots when exposed, but absence does not establish that a window has no native tabs. No tab-group discovery is claimed.

The recorder makes three bounded subscription/enumeration retry passes for each initial or newly launched app, with nominal delays of 1, 2, and 4 seconds between passes. Confirmed notification registrations are cached per observer and AX element; failed requests remain retryable. `subscriptionRetry` marks an attempted pass, not successful coverage. AX calls can delay these passes and event delivery. Stop and application termination cancel pending retries. Missing windows are never treated as closed by reconciliation; continuous reconciliation remains future work.

Repeat `--bundle-id` to record several specific apps; omitting it records all discovered apps. Filters apply to initial discovery and workspace launch/termination notifications. JSONL output is written immediately so a pipe reader can wait for `recorderReady` before interacting.

An opt-in live integration check creates a disposable AppKit app, records only its bundle ID, and checks launch, create, move, resize, minimize, restore, close, and termination delivery, including stable create/destroy window IDs:

```sh
ruby scripts/check-ax-recorder.rb
```

It requires a GUI session and Accessibility trust for the built CLI. The fixture briefly shows a background window and Dock icon, changes only its own window, then quits. Its temporary bundle and logs are removed after the check. It runs separately from unit tests. This validates a regular AppKit fixture, not other apps or the native-tab/popup/display/Space-transfer gates. The accessory-app fixture experiment on the initial host did not deliver workspace launch/termination events; newly launched accessory apps can therefore be missed until a fresh recording discovers them.

See [implementation status](docs/STATUS.md) and [manual feasibility protocol](docs/FEASIBILITY.md).

For native-tab investigation, `paperi tab-evidence bundle.identifier` captures a bounded AX structural graph for one app. It includes roles, boolean selection state, named relationships, attribute-query errors, and window IDs, with no titles or string values. Local graph node IDs are capture-local. Traversal stops at depth 5, 128 nodes, or a one-second per-app traversal budget (plus an in-flight AX call); truncation is explicit.

`ruby scripts/check-native-tabs.rb [new-output.json]` runs an opt-in disposable native-tab fixture through merge, selection, detach, remerge, active close and last close. It saves ground truth alongside AX evidence, by default to ignored `captures/native-tab-fixture.json`, and refuses to overwrite existing output. This is an investigation, not a native-tab acceptance test. On the initial host, both background and key-window experiments returned successful but empty AX window enumeration while the fixture confirmed native tab operations. This remains inconclusive for cross-process grouping.

The harness now keeps one observer session alive with `paperi record 20 --bundle-id identifier --tab-evidence`. This opt-in mode requires exactly one bundle ID and emits bounded structural samples roughly once per second. Samples distinguish `roots` from `observedRoots`; references delivered by creation/focus notifications are retained until confirmed destruction or recorder teardown. Capture start/end uptime lets the harness reject samples that span a fixture transition. Graph reads can delay notification processing, so this mode is not a latency benchmark.

In the persistent fixture session, enumeration exposes two separate windows, one active representative after merge, and two windows after detach; retained observer roots include inactive members until confirmed close. A child `AXTabGroup` exposes `AXTabs` and boolean tab selection, while the window root itself does not support `AXTabs`. Both tab controls refer back to the active physical window, so they do not establish a mapping to every inactive member ID. The earlier empty one-shot captures and the persistent session differ; the cause is not established. Daily-app grouping remains a release gate.
