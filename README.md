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

`record --bundle-id identifier --reconcile-every 1` opts into periodic fresh app/window discovery, including apps missed by workspace launch notifications. The interval must be 1–30 seconds and exactly one bundle ID is required. Polling is disabled by default, uses the current running-app list, and never treats absence as termination or closure. `recorderReconciled` reports attempted discovery, not completeness; AX work can delay ticks. Recording end cancels the timer and stops native observation.

The recorder makes three bounded subscription/enumeration retry passes for each initial or newly launched app, with nominal delays of 1, 2, and 4 seconds between passes. Confirmed notification registrations are cached per observer and AX element; failed requests remain retryable. `subscriptionRetry` marks an attempted pass, not successful coverage. AX calls can delay these passes and event delivery. Stop and application termination cancel pending retries. Missing windows are never treated as closed by reconciliation; continuous reconciliation remains future work.

Repeat `--bundle-id` to record several specific apps; omitting it records all discovered apps. Filters apply to initial discovery and workspace launch/termination notifications. JSONL output is written immediately so a pipe reader can wait for `recorderReady` before interacting.

`record --restart-after seconds` performs one diagnostic stop/start strictly within the recording interval. It emits another `recorderReady`, then `recorderRestarted` with actual native-source removal counts; `recordingEnded` also includes teardown evidence. `ruby scripts/check-native-tabs.rb --restart [new-output.json]` checks a learned native group before and after replacement (about 42 seconds). The replacement gets a fresh identity scope and only currently observed bindings. Inactive physical roots may be absent until rediscovered; restart never carries them forward as confirmed membership.

Each recorder start also has a private run token. Workspace and native callbacks from an older run are rejected even if delivery was already queued when observation stopped. Source removal, duplicate notification delivery and complete window-event coverage are checked separately; empty AX enumeration can still make restart recovery inconclusive.

Reconciliation now also queries fresh `AXFocusedWindow` and `AXMainWindow` references. Every discovery reference must match the observer PID and have a window/sheet role; equal references share one subscription. `windowDiscovery` records query errors, accepted source provenance and rejected-reference counts. These fresh channels can recover a current window when enumeration omits it, but they neither restore old-scope state nor establish inactive-tab membership. Native fixture reports preserve discovery passes under schema 11.

Tab/window evidence includes `windowCoverage`: `noReferences`, `unusableReferences`, `referencesAvailable` or `truncated`, with a usable-root count. These describe the sample, not a complete application inventory; `confirmsEmptyWindowSet` remains false. Tab associations are unavailable when no usable roots exist, including after known windows close. Confirmed destruction still removes each known reference, but an empty sample never becomes proof that the app has no other windows.

`paperi window-evidence identifier` and `record --bundle-id identifier --window-evidence` collect bounded window-policy facts and per-app focus metadata without titles, text or geometry values. Enumeration and retained observer references stay separate; direct window/sheet children are inspected too. Unknown fullscreen/minimized metadata remains pending for otherwise eligible documents; snapshot schema 2 represents unknown presentation flags as `null`.

`ruby scripts/check-popups.rb [new-output.json]` runs a disposable background document, nonactivating panel and attached sheet (about 17 seconds). It checks transient exclusion, continued document notifications after dismissal, and the sheet's focus identity versus its document owner. Per-app focus return after a sheet is narrower than active-app or cross-display recovery. Control Center, context menus, modal file panels and the original blocking popup still require real interaction traces.

An opt-in live integration check creates a disposable AppKit app, records only its bundle ID, and checks launch, create, move, resize, minimize, restore, close, and termination delivery, including stable create/destroy window IDs:

```sh
ruby scripts/check-ax-recorder.rb
```

It requires a GUI session and Accessibility trust for the built CLI. The fixture briefly shows a background window and Dock icon, changes only its own window, then quits. Its temporary bundle and logs are removed after the check. It runs separately from unit tests. This validates a regular AppKit fixture, not other apps or the native-tab/popup/display/Space-transfer gates. The accessory-app fixture experiment on the initial host did not deliver workspace launch/termination events; newly launched accessory apps can therefore be missed until a fresh recording discovers them.

`ruby scripts/check-ax-recorder.rb --accessory [new-output.json]` repeats the window lifecycle with an accessory app and one-second reconciliation (about 19 seconds). It verifies fresh discovery, single create/destroy delivery and final native/workspace teardown without requiring workspace launch/termination notifications. The fixture delays window creation to let polling attach before its actions; this is not evidence of capturing events that occurred before attachment.

`ruby scripts/check-diagnostics.rb --cycles 2 [new-output-directory]` runs all eight controlled diagnostic modes sequentially and preserves individual reports/logs plus a cumulative summary. One cycle is the default; one to five cycles are accepted. Each cycle takes roughly three to four minutes. Required failures produce a nonzero exit; native enumeration and restart inventory remain explicit informational checks. The runner refuses an existing output directory. `check-ax-recorder.rb [new-output.json]` can also save its report separately from build output.

See [implementation status](docs/STATUS.md) and [manual feasibility protocol](docs/FEASIBILITY.md).

For native-tab investigation, `paperi tab-evidence bundle.identifier` captures a bounded AX structural graph for one app. It includes roles, boolean selection state, named relationships, attribute-query errors, and window IDs, with no titles or string values. Local graph node IDs are capture-local. Traversal stops at depth 5, 128 nodes, or a one-second per-app traversal budget (plus an in-flight AX call); truncation is explicit.

`ruby scripts/check-native-tabs.rb [new-output.json]` runs an opt-in disposable native-tab fixture through merge, selection, detach, remerge, active close and last close. It saves ground truth alongside AX evidence, by default to ignored `captures/native-tab-fixture.json`, and refuses to overwrite existing output. This is an investigation, not a native-tab acceptance test. On the initial host, both background and key-window experiments returned successful but empty AX window enumeration while the fixture confirmed native tab operations. This remains inconclusive for cross-process grouping.

The harness now keeps one observer session alive with `paperi record 20 --bundle-id identifier --tab-evidence`. This opt-in mode requires exactly one bundle ID and emits bounded structural samples roughly once per second. Samples distinguish `roots` from `observedRoots`; references delivered by creation/focus notifications are retained until confirmed destruction or recorder teardown. Capture start/end uptime lets the harness reject samples that span a fixture transition. Graph reads can delay notification processing, so this mode is not a latency benchmark.

In the persistent fixture session, enumeration exposes two separate windows, one active representative after merge, and two windows after detach; retained observer roots include inactive members until confirmed close. A child `AXTabGroup` exposes `AXTabs` and boolean tab selection, while the window root itself does not support `AXTabs`. Both tab controls refer back to the active physical window, so they do not establish a mapping to every inactive member ID. The earlier empty one-shot captures and the persistent session differ; the cause is not established. Daily-app grouping remains a release gate.

Use `ruby scripts/check-native-tabs.rb --multi [new-output.json]` for two tab groups plus an independent window. The five identically titled fixture windows exercise independent selection, detach, moving a member into the other group, active close, and final cleanup. Reports check observer root identity and tab-group ownership separately from AX enumeration. Enumeration can remain empty even when observer-backed structure is complete; that failure is reported independently. The checks use the fixture's own ground truth and do not implement a cross-process membership resolver.

The latest single- and multiple-container runs returned empty AX enumeration despite complete observer-backed tab structure. Earlier successful enumeration is a recorded observation, not a guarantee; the cause of the difference remains unresolved.

Persistent tab captures also include `axIdentity` equality tokens under an observer-specific `identityScope`. These compare retained AX references using `CFEqual`; they are diagnostic tokens, not durable tab IDs. A scope retains at most 512 references, never recycles tokens, reports exhaustion explicitly, and is released with its observer. One-shot captures do not provide these cross-sample tokens.

The harness compares group/control tokens through selection changes and reports observed selected-control/window bindings. In the controlled two-group fixture, both groups and their ordered control tokens remain equal through switching away and back, and selecting each control reveals a distinct physical member. This supports observed-selection association only. Unvisited tabs, regrouping, AX identity reuse, daily-app differences and enumeration failures still require explicit handling before any live grouping policy.

Persistent reports now include diagnostic `selectionAssociations` candidates. The tracker learns only an affirmatively selected control's physical owner; unvisited controls stay unresolved. A candidate becomes complete only after every control has been observed selected. Any scope, group-set or ordered-control change clears learned bindings; incomplete metadata and confirmed window destruction also discard them. Conflicting physical owners quarantine the implicated groups until observer replacement; shared or malformed AX identities quarantine the whole scope. This intentionally conservative tracker is not connected to layout commands or native-tab classification; ordinary content tabs may expose similar AX roles.

With complete group/control structure and ownership, missing or ambiguous selection now withholds only that group's bindings. Reports expose `selectionKnown` per group and `unavailableGroups`; unrelated groups retain learning. Unknown ownership/topology, capture truncation and identity exhaustion still withhold the entire capture. An unavailable group's current physical owner still participates in conflict detection. `ruby scripts/check-native-tabs.rb --partial [new-output.json]` verifies a two-tab group can complete beside a three-tab group with an unvisited member.

`ruby scripts/check-native-tabs.rb --content [new-output.json]` adds a real two-item `NSTabView` to the independent window alongside the two native groups. It verifies content selection, visible AX tab structure, withholding of complete content associations, isolated group quarantine after both content controls claim the same physical window. Radio-button `AXValue` accepts booleans or exactly numeric zero/one and records the encoding; other roles, attributes and numeric values are not normalized. The collector requests `AXValue` only for radio controls. Passing this negative control demonstrates conservative withholding, not a general native-vs-content-tab classifier.

Association reports expose quarantine separately from evidence status: `quarantined` can remain true while `status` is `unavailable` during an incomplete capture. Missing metadata does not clear a previously detected identity conflict.

`ruby scripts/check-native-tabs.rb --unvisited [new-output.json]` exercises three native tabs, initially visiting only two. On this host, the unvisited control omits `AXValue`, so the collector withholds the candidate even though its physical window is known. After the third tab is selected, learning starts fresh; revisiting the earlier tabs can complete the unchanged candidate. This fixture takes about 29 seconds and checks that missing selection metadata never causes inferred or replayed bindings.

Increment 18 narrows physical-owner conflict quarantine to the implicated groups: unrelated groups continue learning, including both native groups in the mixed content fixture. Shared or malformed AX identities still quarantine the whole observer. Reports distinguish `scopeQuarantined` and retained `quarantinedGroups`, with a `quarantined` flag on each candidate. Group quarantine survives topology changes, disappearance and destruction invalidation until a new observer scope. An `observed` report can include both blocked and usable candidates; blocked candidates have no bindings and cannot be complete. This supersedes the whole-scope physical-owner policy described above.
