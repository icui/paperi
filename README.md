# Paperi

Standalone macOS scrolling window manager (PaperWM-style) in development.

## Install for daily use

```sh
./scripts/install.sh                  # release build → ~/Applications/Paperi.app, restarts it (--no-launch: install only)
open ~/Applications/Paperi.app        # grant Accessibility when prompted
```

The ▥ menu bar item shows status and offers Pause/Resume, Retile, Reload Config, Open Config…, Start at Login and Stop & Restore Windows. The app's ad hoc signature pins its designated requirement to the bundle identifier (`dev.paperi.app`), so one Accessibility grant survives rebuilds and reinstalls. This is weaker than a real signing identity (any local binary with that identifier would match); set `PAPERI_SIGN_IDENTITY` to use one. If a grant has no effect, an entry for an older build is stale: run `tccutil reset Accessibility dev.paperi.app`, relaunch, and grant again. `paperi login on|off|status` manages the LaunchAgent (prefers the installed app; log in `~/Library/Logs/Paperi.log`). Quit Hammerspoon/PaperWM first; rollback is Stop & Restore, `paperi login off`, then start Hammerspoon again.

## Live mode

```sh
./scripts/swift.sh build
.build/debug/paperi run -v            # all regular apps; or limit with --app ID ...
```

Manages the windows of every regular (Dock-visible) app on each display's active Space as one horizontally scrolling strip, including native macOS tab containers and Mission Control Space transfers. Only real document windows are tiled: menus, popovers, sheets, dialogs, panels, Control Center and Spotlight are never touched, and windows without a fullscreen button (Open/Save panels, Finder Get Info, System Settings) float. It registers the Option–Command shortcuts from the PaperWM Hammerspoon config by default (configurable below; `--no-hotkeys` disables them); every shortcut runs the same command as `paperi msg`:

| Keys (⌥⌘) | Command | Effect |
| --- | --- | --- |
| J / K | `focus left\|right` | Focus the adjacent column (nearest row), scrolling it into view; at the end of the strip (or with no managed window focused) a short accent bar flashes on that edge of the focused window; J/K never switch Spaces |
| — | `focus up\|down` | Focus the stacked window above/below |
| Arrows | `swap left\|right\|up\|down` | Swap columns or stacked rows |
| L / H | `width +\|- [fraction]` | Width ±10% of the canvas |
| U / N | `height +\|- [fraction]` | Height ±10%, redistributing the stack |
| C / S | `center`, `split` | Center the focused column; split it with its left neighbour |
| I / O | `slurp`, `barf` | Stack into the left column / unstack into its own column |
| F | `float` | Toggle the focused container out of / back into the strip |
| — | Mission Control | Move windows between Spaces and displays by dragging them in Mission Control; the container (with its tabs and width) follows to the destination strip and, once Mission Control closes, is focused if it landed on a shown Space |
| — | `retile`, `status`, `pause`, `resume`, `reload`, `stop` | Reapply layout; JSON state; pause/resume management (windows stay put); reload config; stop and restore original frames |

Quit Hammerspoon (or stop PaperWM) first: a combination already registered by another process is reported in `hotkeyFailures` and left to that process.

`paperi check-apps [ID …]` (read-only) shows what live mode would decide for each on-screen window. Optional `~/Library/Application Support/Paperi/config.json` (all keys optional):

```json
{
  "exclude": ["us.zoom.xos"],
  "float": [{"app": "com.apple.finder", "titleContains": "Copy"}],
  "tile": [{"app": "com.apple.systempreferences"}],
  "singleton": ["com.google.Chrome"],
  "include": null, "gap": 8, "outerGap": 8, "swapHighlight": "#0A84FF4D",
  "hotkeys": { "ctrl-alt-l": "width + 0.2", "alt-cmd-1": null }
}
```

`exclude` skips apps, `float` keeps matching windows out of the strip, `tile` overrides the no-fullscreen-button rule, `singleton` (or `--singleton-app`) treats an app's in-content tab bar as a plain window, `include` (or `--app`) limits management to listed apps, and `hotkeys` maps key specs (`ctrl`/`alt`/`shift`/`cmd` plus a letter, digit, arrow, `f1`–`f20`, `space`, `return`, `tab`, `escape`, punctuation names) to `paperi msg` commands, merged over the defaults; `null` removes a default. `swapHighlight` (`#RRGGBB` or `#RRGGBBAA`) colours the mask over the window a dragged window will swap with when released (any window in the adjacent columns or its own stack). Displays must be arranged above or below each other (System Settings › Displays): with displays side by side, windows scrolled past the shared edge would jump to the other display, so Paperi pauses with a short explanation and resumes once they are stacked. Invalid entries are reported at startup and in `status` rather than ignored. Reload with the menu or `paperi msg reload`. System UI agents are always excluded. Ctrl-C or `paperi msg stop` restores admission frames; after a crash, `paperi restore` uses the persisted journal. The responsible terminal/editor (or `dist/Paperi.app`) needs Accessibility access. See [docs/STATUS.md](docs/STATUS.md) for verified scope and limits.

## Disposable preview

```sh
./scripts/swift.sh run --skip-build paperi preview-fixture
```

Click one of its two document windows, then use **Narrower/Wider/Stack/Unstack** or local **Option–Command–H/L/I/O**. **Stop & Restore** or **Escape** restores saved frames and closes the preview; it also stops automatically after 60 seconds. Accessibility trust is required.

Standalone macOS scrolling window manager in development. See [plan.md](plan.md) for the intended behavior and release gates, and [docs/STATUS.md](docs/STATUS.md) for current capability status and handoff details.

The current implementation provides a pure Swift layout core (including resize, split, stacked-column slurp/barf, and floating transitions), scoped per-Space/per-display session management (`ScopedLayoutSession`, `DisplaySpaceCoordinator`), active-first and strict native-tab discovery and lifecycle reconciliation (`NativeTabMembership`, `NativeTabTopology`), following of user Mission Control moves across Spaces and displays, opt-in disposable and real-app probes (Finder and Terminal), regression tests, read-only native diagnostics, and an inactive menu bar shell. Live mode manages all regular apps (configurable) and registers the user's Option–Command shortcuts while running.

`./scripts/swift.sh build` followed by `./scripts/swift.sh run --skip-build paperi probe-placement` runs an opt-in AX effect test on a newly spawned disposable fixture only. It applies a pure-core frame using size → position → size, confirms the observed frame within two points, restores and confirms the original frame, then terminates the fixture. Accessibility trust is required. It accepts no PID/window arguments and never targets existing user windows. Its scope is ordinary single-window placement, without focus changes, hotkeys or Space movement; it is not an enabled manager.

`./scripts/swift.sh run --skip-build paperi probe-lifecycle` exercises the next integration step (about 12 seconds): a new non-tabbing fixture creates two windows and closes them in order. Native create/destroy events drive the existing lifecycle reducer, whose layouts are applied and confirmed through AX. Closing the left window must reflow the survivor; the final state must be empty with clean native-source teardown. Changed-frame checks skip redundant writes; move/resize echoes are counted but do not request another layout. This command accepts no existing app/window selection. It does not yet implement external resize, focus management, native tabs or a production effect scheduler. See the [agreed implementation order](plan.md#agreed-implementation-order--2026-11-08).

`paperi probe-resize` adds a fixture-originated width change to that lifecycle sequence. Expected AX frames are tracked per window and request generation for up to 1.5 seconds; matching notifications do not request layout, while a mismatched resize remains observable during a pending write. The current representative's column width is adopted without changing its logical identity or focus, then neighbor reflow is confirmed. The check requires one adoption matching fixture ground truth. This is horizontal resizing of deliberately non-tabbing fixture windows only; external moves, stacked-height changes, focus management and general scheduling remain work ahead.

`paperi probe-interaction` runs three scripted width commands against fresh per-app focused-window metadata: on a document, while a utility panel owns key focus, and after document focus returns. Only the first and last may change layout; the middle command must produce zero writes and must never replay. Native focus notifications also update logical focus/suppression. The fixture changes key windows inside its own application; Paperi issues no AX focus/activation requests. Panels are classified before tiled Space ownership is required, and fresh focus/main references supplement AXWindows. This does not install global shortcuts or establish OS-wide/cross-display popup recovery.

The lifecycle probes now use a reusable scoped session for state, logical IDs, Space ownership and frame expectations. Its default command policy requires the actual frontmost PID to match its owner; fixture-only callers explicitly use application-local ownership. It defaults to rejecting unknown native-tab membership. Stopping invalidates the session ticket and clears pending state so queued work cannot be applied to a replacement session. This state boundary does not itself restore native geometry; restoration and observer teardown remain adapter responsibilities. No user-window preview is enabled yet.

`paperi probe-stop` stops while both new fixture windows are still open. The adapter invalidates management, removes observation, restores the first saved frame of each surviving eligible window and confirms it within two points. It revalidates PID, reference, role, Space and presentation before restoration writes. Confirmed closed windows are removed from the recovery journal. Repeated stop is a no-op; restoration failure is reported without automatic retries. The check also attempts an old-ticket command/effect after stop and requires zero management writes. This covers normal controlled stop, not crash recovery or a general user-window preview.

`paperi probe-preview-input` validates the preview's AppKit input, lazy native-tab reconciliation, and stacked-column path automatically: it activates only its disposable child, merges the two preview windows into a native tab group (reconciling into 1 slot immediately before visiting the background tab), switches tabs A→B→A, detaches back to 2 columns, invokes local key-equivalent handlers for grow/shrink (`⌥⌘L`/`⌥⌘H`) and stacked-column slurp/barf (`⌥⌘I`/`⌥⌘O`), then clicks its actual Stop button through AppKit. It posts no system-wide keyboard events. Accepted requests require that child's PID, run token, known window and a new sequence number. Resize/stack dispatch and each command-induced AX write require the child to remain frontmost. This is not a physical-keyboard test or global-shortcut registration.

`paperi probe-native-tab-session` runs a roughly 21-second native AppKit tab experiment on a new disposable child. External AX selection observations learn distinct members before admitting one logical container. Selected-member Space evidence is scoped to that group because inactive native tabs can lack window-server entries. Fresh active-window identity, policy and Space checks guard geometry writes. Further tab switches preserve the logical slot; scripted width changes prove writes target the new representative. Detachment or evidence loss stops management and restores the two original frames. Fixture ground truth is read only afterward for validation. It accepts no existing app/PID/window arguments. Continued management through merge/detach/closure and real-app compatibility remain unfinished.

`paperi probe-native-tab-lifecycle` extends that experiment to about 27 seconds and continues through detach, re-merge, active-tab closure and last-tab closure. Detach keeps the existing slot with its old active member and creates a neighboring slot for the other; merge keeps the selected member's slot and width. Unlearned or incomplete topology produces no management writes. Only destruction notifications prove closure, and closing the active member retains the survivor's logical container. This mode handles previously admitted members in one-slot columns; the growth mode below adds new members. Stacked columns and real-app compatibility remain unverified.

`paperi probe-native-tab-growth` adds a third native tab after management has started, then selects and closes it before closing the remaining group. Admission requires a creation notification, complete learned membership in an existing group, valid member references and same-group selected-member Space evidence. Creation alone never admits an unrelated window. The original logical slot and width are retained. The script takes about 49 seconds after AppKit launch, with a 75-second overall bound to allow startup. The native adapter captures direct tab bars from fresh representative roots and validates cached inactive references separately. Every member must be visited to learn a changed group; incomplete evidence withholds writes. Queued final destruction is reconciled before stop. It targets only the new disposable child; stacked-column and real-app compatibility remain unverified.

`ruby scripts/check-finder-documents.rb [--new-tab] new-output-directory` is a separate real-app discovery and native-tab verification harness. It creates two Finder windows pointing to temporary folders, optionally focuses one recorded test ID, invokes Finder's New Tab menu item and switches A→B→A across the two tabs while verifying the second window as a tab-bar-free singleton (`singletonCandidates`), then closes recorded test IDs. It never merges windows, changes Finder preferences or performs geometry writes. `--new-tab` also needs System Events automation access.

`ruby scripts/check-terminal-tabs.rb new-output-directory` creates an idle, uniquely tagged Terminal test window and a native tab through the app's nested New Tab menu. It tracks physical representative IDs, selects A→B→A and records the same direct tab-bar adapter used by the demo. The report separates discovery/teardown checks from `sharedMembershipVerified`; `tabSupport` remains unverified in discovery-only mode because Terminal geometry effects are not tested. Cleanup closes only idle tabs carrying that run's exact tag and rechecks after each close as native representatives change. Tags are test ownership evidence, not adapter membership evidence. Existing windows, profiles and preferences are not modified. Terminal and System Events automation access are required.

Add `--placement` to first learn the exact owned native baseline, then translate each selected test representative by 24 points and restore its original frame through AX during a second A→B→A sequence. Effects are refused without that baseline. The probe derives the target from the layout core and writes position only; Terminal cell-grid resizing is not tested. Each write requires the exact UUID test tag, idle selected tab, frontmost Terminal PID, matching AX identity, eligible presentation and unchanged Space. Recovery is attempted even after partial write failure. The combined report requires both confirmed translation/restoration and a retained final native membership mapping.

Use `--resize` instead of `--placement` to measure one column's width on the owned test tab, restore that calibration, then request a four-column AXSize increase and restore the original frame. The target comes from core placements; both actual frame geometry and Terminal's reported column counts must agree. It reuses the exact baseline/ownership checks, retains native membership and cleans up the tagged windows.

Use `--session` (`paperi probe-terminal-session <tag>`) to run a sustained shared-session native-tab lifecycle on the owned Terminal test tabs. It learns initial two-tab membership externally via `NativeTabMembership`, admits a single logical slot into `ScopedLayoutSession`, switches A→B→A while applying core placements via `AXPosition`, creates a third tab and withholds writes until all members are visited and `AXWindowCreated` + selection relearning admit the new member into the same logical slot, reconciles active-tab closures (`3→2→1`) and final tab closure (`1→0`) via `AXWindowUIElementDestroyed`, restores surviving frames on stop via `FrameRestorationJournal`, and cleans up all tagged tabs.

See the [pinned-source comparison](docs/REFERENCE-AUDIT.md) for the implementation direction. Adapted source notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

`paperi mission-control-move WID SPACE` is a test aid: it drags a real window onto a Space thumbnail in Mission Control (on whichever display hosts that Space), as a user would, so a running live mode can be checked following the move. Live mode itself never moves windows between Spaces.

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

When running through a restricted coding-agent sandbox, an active-developer-directory or toolchain-access failure can reflect sandbox restrictions even when Command Line Tools are installed. Retry the same build/test command with approved access outside the sandbox before changing the system developer directory or installing another toolchain. The full debug build and 26 core regressions have passed this way; see [validation results](docs/HISTORY.md#validation-on-the-initial-host).

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

The recorder makes three bounded subscription/enumeration retry passes for each initial or newly launched app, with nominal delays of 1, 2, and 4 seconds between passes. Confirmed notification registrations are cached per observer and AX element; failed requests remain retryable. `subscriptionRetry` marks an attempted pass, not successful coverage. AX calls can delay these passes and event delivery. Stop and application termination cancel pending retries. Missing windows are never treated as closed by reconciliation. Further periodic discovery requires the explicit scoped option described above.

Repeat `--bundle-id` to record several specific apps; omitting it records all discovered apps. Filters apply to initial discovery and workspace launch/termination notifications. JSONL output is written immediately so a pipe reader can wait for `recorderReady` before interacting.

`record --restart-after seconds` performs one diagnostic stop/start strictly within the recording interval. It emits another `recorderReady`, then `recorderRestarted` with actual native-source removal counts; `recordingEnded` also includes teardown evidence. `ruby scripts/check-native-tabs.rb --restart [new-output.json]` checks a learned native group before and after replacement (about 42 seconds). The replacement gets a fresh identity scope and only currently observed bindings. Inactive physical roots may be absent until rediscovered; restart never carries them forward as confirmed membership.

Each recorder start also has a private run token. Workspace and native callbacks from an older run are rejected even if delivery was already queued when observation stopped. Source removal, duplicate notification delivery and complete window-event coverage are checked separately; empty AX enumeration can still make restart recovery inconclusive.

Fresh discovery also inspects up to 128 direct application `AXChildren`, accepting only references with the expected PID and window/sheet role. It never descends into child trees. `windowDiscovery` preserves `AXChildren` provenance, its query result, `directChildCount` and `directChildrenTruncated`; rejected menus and other non-window children never become subscriptions. This provides another discovery channel without claiming a complete inventory or restoring old recorder state.

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

`record --poll-only` explicitly disables workspace launch/termination listeners and requires scoped periodic reconciliation. Initial discovery and native AX notifications remain enabled. `recorderReady` reports `workspaceEventsEnabled`. `ruby scripts/check-ax-recorder.rb --poll-only [new-output.json]` launches the accessory fixture after readiness and verifies discovery with no workspace callbacks, matching window identity and clean teardown. This isolates polling recovery without depending on whether this host happens to deliver accessory-app workspace events.

Native fixture schema 13 preserves a compact `associationTimeline` for every structural sample, including intermediate captures between fixture stages. It also lists failed required checks separately from informational enumeration/inventory results. A repeated successful capture does not override an earlier inconclusive result.

Native fixture schema 14 also retains `selectionAssociations.evidenceIssues` in that timeline. These identify the first structural rejection or each unavailable selection value with a capture-local node, attribute and AX error code where available. `AXSelectedError` and radio-control `AXValueError` preserve the actual query result without collecting string values. A successful read with no accepted boolean still withholds selection; its zero error code does not imply usable metadata. Incomplete capture issues must be read alongside reference coverage and truncation flags. This explains the observed evidence decision without claiming a platform-level cause for a failed read.

Unreadable roles anywhere in the sampled graph also make association evidence unavailable: an unknown node could hide a tab group, so it cannot establish an observed empty topology. Role/subrole query codes are retained as well. `ruby scripts/check-native-tabs.rb --restart --reconcile [new-output.json]` adds one-second periodic fresh discovery to the same restart fixture without changing its required checks. Native fixture schema 15 records whether that option was enabled.

Schema 16 retains `truncationReasons` (`depthLimit`, `nodeLimit`, `timeBudget`) in every association timeline sample. Even a short capture can hit a structural limit; capture duration alone does not establish why learning was discarded. The traversal limits and invalidation policy remain unchanged.

Schema 17 adds `rootValidations`: each enumerated/observed root must have a matching PID and an AXWindow/AXSheet role before tab diagnostics traverse its relationships. Rejected roots retain role/PID query results without following application/menu or foreign trees. A rejected root withholds association learning even beside otherwise usable roots; it never confirms an empty inventory.

Schema 18 separates `noDuplicateKnownWindowEvents`, `windowEventIdentitiesComplete` and `windowEventCoverageComplete`. Zero, missing or malformed window IDs are unresolved identities, not proof of duplicate delivery. They still fail required identity/coverage checks. `windowEventEvidence` preserves known duplicates and the unresolved-event count. Run the harness metric regressions with `ruby Tests/DiagnosticsTests/window_event_evidence_test.rb`.

Schema 19 retains per-capture `roleReadRetries` in the association timeline. An AXRole query returning `cannotComplete` (-25201) gets at most one immediate fresh read within the existing capture deadline. Each retry records its node, both AX result codes and whether a nonempty role was recovered. Failed retries still withhold learning; other errors and successful reads with missing/malformed roles are not retried. No prior role or association is used as fallback.

`ruby scripts/check-diagnostics.rb --cycles 2 [new-output-directory]` runs all ten controlled diagnostic modes sequentially, including baseline and periodically reconciled restart, and preserves individual reports/logs plus a cumulative summary. One cycle is the default; one to five cycles are accepted. Each cycle takes roughly five minutes. Required failures produce a nonzero exit; native enumeration and restart inventory remain explicit informational checks. The runner refuses an existing output directory. `check-ax-recorder.rb [new-output.json]` can also save its report separately from build output.

Repeated-run summary schema 2 records the base revision, whether local edits exist, and a SHA-256 fingerprint of build/test/fixture inputs, including untracked inputs. The fingerprint is checked after every mode and at completion; source changes during a cycle prevent an overall pass. Documentation edits are outside this fingerprint. A dirty run is evidence for its captured source fingerprint, not a claim about the base commit alone.

See [implementation status](docs/STATUS.md) and [manual feasibility protocol](docs/FEASIBILITY.md).

For native-tab investigation, `paperi tab-evidence bundle.identifier` captures a bounded AX structural graph for one app. It includes roles, boolean selection state, named relationships, attribute-query errors, and window IDs, with no titles or string values. Local graph node IDs are capture-local. Traversal stops at depth 5, 128 nodes, or a one-second per-app traversal budget (plus an in-flight AX call); truncation is explicit.

`ruby scripts/check-native-tabs.rb [new-output.json]` runs an opt-in disposable native-tab fixture through merge, selection, detach, remerge, active close and last close. It saves ground truth alongside AX evidence, by default to ignored `captures/native-tab-fixture.json`, and refuses to overwrite existing output. This is an investigation, not a native-tab acceptance test. On the initial host, both background and key-window experiments returned successful but empty AX window enumeration while the fixture confirmed native tab operations. This remains inconclusive for cross-process grouping.

The harness now keeps one observer session alive with `paperi record 20 --bundle-id identifier --tab-evidence`. This opt-in mode requires exactly one bundle ID and emits bounded structural samples roughly once per second. Samples distinguish `roots` from `observedRoots`; references delivered by creation/focus notifications are retained until confirmed destruction or recorder teardown. Capture start/end uptime lets the harness reject samples that span a fixture transition. Graph reads can delay notification processing, so this mode is not a latency benchmark.

In the persistent fixture session, enumeration exposes two separate windows, one active representative after merge, and two windows after detach; retained observer roots include inactive members until confirmed close. A child `AXTabGroup` exposes `AXTabs` and boolean tab selection, while the window root itself does not support `AXTabs`. Both tab controls refer back to the active physical window, so they do not establish a mapping to every inactive member ID. The earlier empty one-shot captures and the persistent session differ; the cause is not established. Daily-app grouping remains a release gate.

Use `ruby scripts/check-native-tabs.rb --multi [new-output.json]` for two tab groups plus an independent window. The five identically titled fixture windows exercise independent selection, detach, moving a member into the other group, active close, and final cleanup. Reports check observer root identity and tab-group ownership separately from AX enumeration. Enumeration can remain empty even when observer-backed structure is complete; that failure is reported independently. The checks use the fixture's own ground truth and do not implement a cross-process membership resolver.

The latest single- and multiple-container runs returned empty AX enumeration despite complete observer-backed tab structure. Earlier successful enumeration is a recorded observation, not a guarantee; the cause of the difference remains unresolved.

Persistent tab captures also include `axIdentity` equality tokens under an observer-specific `identityScope`. These compare retained AX references using `CFEqual`; they are diagnostic tokens, not durable tab IDs. A scope retains at most 512 references, never recycles tokens, reports exhaustion explicitly, and is released with its observer. One-shot captures do not provide these cross-sample tokens.

The harness compares group/control tokens through selection changes and reports observed selected-control/window bindings. In the controlled two-group fixture, both groups and their ordered control tokens remain equal through switching away and back, and selecting each control reveals a distinct physical member. This supports observed-selection association only. Unvisited tabs, regrouping, AX identity reuse, daily-app differences and enumeration failures still require explicit handling before any live grouping policy.

Persistent reports now include diagnostic `selectionAssociations` candidates. The tracker learns only an affirmatively selected control's physical owner; unvisited controls stay unresolved. A candidate becomes complete only after every control has been observed selected. Any scope, group-set or ordered-control change clears learned bindings; incomplete metadata and confirmed window destruction also discard them. The `resets` array identifies actual discarded bindings by reason, group token and count. It appears once in the next report, including destruction between samples; empty learning produces no reset entry. Missing capture evidence does not distinguish individual AX read failures. Conflicting physical owners quarantine the implicated groups until observer replacement; shared or malformed AX identities quarantine the whole scope. This intentionally conservative tracker is not connected to layout commands or native-tab classification; ordinary content tabs may expose similar AX roles.

With complete group/control structure and ownership, missing or ambiguous selection now withholds only that group's bindings. Reports expose `selectionKnown` per group and `unavailableGroups`; unrelated groups retain learning. Unknown ownership/topology, capture truncation and identity exhaustion still withhold the entire capture. An unavailable group's current physical owner still participates in conflict detection. `ruby scripts/check-native-tabs.rb --partial [new-output.json]` verifies a two-tab group can complete beside a three-tab group with an unvisited member.

`ruby scripts/check-native-tabs.rb --content [new-output.json]` adds a real two-item `NSTabView` to the independent window alongside the two native groups. It verifies content selection, visible AX tab structure, withholding of complete content associations, isolated group quarantine after both content controls claim the same physical window. Radio-button `AXValue` accepts booleans or exactly numeric zero/one and records the encoding; other roles, attributes and numeric values are not normalized. The collector requests `AXValue` only for radio controls. Passing this negative control demonstrates conservative withholding, not a general native-vs-content-tab classifier.

Association reports expose quarantine separately from evidence status: `quarantined` can remain true while `status` is `unavailable` during an incomplete capture. Missing metadata does not clear a previously detected identity conflict.

`ruby scripts/check-native-tabs.rb --unvisited [new-output.json]` exercises three native tabs, initially visiting only two. On this host, the unvisited control omits `AXValue`, so the collector withholds the candidate even though its physical window is known. After the third tab is selected, learning starts fresh; revisiting the earlier tabs can complete the unchanged candidate. This fixture takes about 29 seconds and checks that missing selection metadata never causes inferred or replayed bindings.

Increment 18 narrows physical-owner conflict quarantine to the implicated groups: unrelated groups continue learning, including both native groups in the mixed content fixture. Shared or malformed AX identities still quarantine the whole observer. Reports distinguish `scopeQuarantined` and retained `quarantinedGroups`, with a `quarantined` flag on each candidate. Group quarantine survives topology changes, disappearance and destruction invalidation until a new observer scope. An `observed` report can include both blocked and usable candidates; blocked candidates have no bindings and cannot be complete. This supersedes the whole-scope physical-owner policy described above.
