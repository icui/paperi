# Implementation status

## Current checkpoint: 2026-11-07

- Diagnostic-only: no window effects, management hotkeys or native observer-to-reducer integration.
- All 70 regressions pass in debug and release (28 core, 42 platform).
- Two rounds of eight live fixtures: 14 pass, two restart cases remain inconclusive because empty AX enumeration prevents rediscovery. Source teardown passes; missing references are never interpreted as closed windows.
- Latest work adds scoped popup evidence, safe unknown presentation state, isolated missing tab-selection metadata, repeated diagnostic checks, stale-callback rejection and validated fresh focus/main discovery channels.
- Next priorities: startup/restart window rediscovery, daily-app native-tab classification, actual OS/cross-display popup recovery and display/Space feasibility. Historical increments below retain their original observations and limits.

## Increment 1: repository, diagnostic shell, and initial core

Implemented:

- Swift package with a platform-independent core, isolated private-API bridge, read-only diagnostics, and a menu bar shell.
- Conservative system-overlay/transient classification and explicit pending metadata states.
- Logical tab-container slots, membership validation, row fallback navigation, column/row swaps, slurp/barf primitives, centering, weighted stacked frames, and edge-clamped virtual positions.
- Section packing and release-target selection as pure functions. No live gesture capture or animation.
- AX snapshots and a bounded-duration event recorder for baseline investigation.
- Regression tests, build tasks, local app bundling/signing script, and a manual feasibility protocol.

Incomplete release gates:

- Step 1: real baseline traces and installed-manager performance measurements.
- Step 2: affirmative native-tab grouping, live multi-display validation, popup reproducer and no-injection Space transfer. The bridge currently only queries Spaces/window IDs.
- Step 3: full event reducer, tab reconciliation, fixture parity against recorded interactions, and broader invariants.
- Steps 4–6: effect scheduler, hotkeys, live incremental registry, configuration, recovery, daily-use soak, notarization and distribution.
- Stretch: native touch capture, page frame placement, animation and live performance validation. Section anchors currently describe pages; the ordinary strip placement function does not yet consume section packing.

The current binary never writes window geometry, changes focus, moves Spaces or installs management shortcuts. Keep it diagnostic-only until the platform feasibility gates are verified.

## Increment 2: additional pure core commands

- Added canvas-relative width and stacked-height resizing. Width stays within the usable canvas; height redistribution keeps sibling rows positive and preserves their relative weights beyond a reserved minimum.
- Added the two-column split command: the left and focused columns occupy equal halves with one gap, including on displays with negative origins. No left column means no change.
- Added a Codable layout state separating tiled and user-floating logical slots. Floating toggles retain native-tab membership and preferred column width, remove empty columns, and reject excluded/pending classifications. Retiling inserts a column after the current tiled focus; this is a deterministic policy awaiting recorded parity fixtures.
- Added four regression tests covering resizing, split geometry, floating tab containers, exclusion, and invalid input.
- Validation in this implementation session: editor diagnostics report no errors. `./scripts/swift.sh test` could not start because `xcode-select` reports no active developer directory. These new tests have not been executed; the host results below apply to increment 1.

These are in-memory commands only; they do not enable window management or resolve the native feasibility gates.

## Increment 3: pure tiled lifecycle reducer

- Added a transactional reducer scoped by its caller to one display/Space layout. Eligible insertion is idempotent; explicit slot removal cleans empty columns and chooses a surviving focus row deterministically.
- Kept OS focus separate from last managed focus. Excluded, pending, and unresolved tiled focus suppress returned layout intent while retaining lifecycle updates. Returning to an eligible document clears suppression without replaying deferred work.
- Added affirmative native-tab membership replacement with global member validation, preserving slot geometry and rejecting conflicting membership atomically. Missing AX enumeration entries are not removal events.
- Added four regression tests for insertion/rollback, overlay isolation/recovery, confirmed tabs, and removal fallback.
- Validation: editor diagnostics report no errors in the new source/tests. `./scripts/swift.sh test` cannot start because this session has no active developer directory; these tests remain unexecuted.

This is the first tiled lifecycle subset of Step 3, not the full event reducer. It is not wired to native observers or an effect scheduler. Floating lifecycle, metadata retries, hide/minimize/fullscreen restoration, cross-display ownership, recorded fixture parity, and actual tab discovery remain open. Native feasibility gates and diagnostic-only operation are unchanged.

## Increment 4: floating lifecycle integration

- Extended the pure lifecycle reducer to retain user-floating slots, handle their explicit removal and confirmed tab updates, and toggle between tiled and floating collections while preserving preferred width and native-tab members.
- Validation spans both collections, so conflicting slot/member identities fail transactionally. Repeated discovery preserves the existing placement mode; transitions require an explicit floating toggle.
- Floating focus clears interaction suppression only for a registered active representative. Unknown floating focus remains suppressed and retains the last tiled focus. Floating commands during suppressed interactions are discarded without replay.
- Floating insertion/removal/tab changes return no tiled layout intent; toggles request layout only when the interaction permits it.
- Added three regressions covering floating lifecycle, cross-collection membership rollback, and focus suppression/toggle recovery. Editor diagnostics report no errors. `./scripts/swift.sh test` still cannot start because no developer directory is active; the new tests remain unexecuted.

The reducer remains in-memory and disconnected from native observers. Metadata retries, hide/minimize/fullscreen restoration, ownership reconciliation, recorded fixture parity, and platform feasibility gates remain open. The app remains diagnostic-only.

## Increment 5: explicit suspension and restoration

- Added explicit whole-container hide, minimize, and fullscreen suspension events to the pure lifecycle reducer. Overlapping reasons are tracked independently; restoration waits until all reasons clear and current classification is eligible.
- Suspended slots reserve their logical and native-tab member identities. Confirmed tab updates remain supported while suspended, and explicit removal discards the saved slot so a later resume cannot resurrect a closed container.
- Retained floating mode, preferred width, and saved stack weight. Tiled restoration rejoins the first surviving original stack sibling, inserting before a surviving following row where possible; without a sibling it creates a column at the saved, clamped index. Existing managed focus is retained. This deterministic fallback still awaits recorded parity evidence.
- Restoration during a suppressed interaction updates state without returning layout intent or clearing focus suppression. No OS focus changes or deferred replay are introduced.
- Added four regression tests covering overlapping reasons and pending metadata, tab identity reservation/close, floating restoration during suppression, and loss of the original stack sibling. Editor diagnostics report no errors. `./scripts/swift.sh test` cannot start because no developer directory is active; tests remain unexecuted.

The platform adapter must confirm these events for the entire logical container; absence from AX enumeration is insufficient. Native observer wiring, metadata retry scheduling, ownership reconciliation, recorded fixture parity, and feasibility gates remain open. The app remains diagnostic-only.

## Increment 6: incremental read-only event recording

- The AX recorder now follows workspace app launch/termination and subscribes window creation/focus discoveries, instead of retaining only the processes/windows seen at startup. Startup is idempotent; stop removes workspace observers and AX run-loop sources. Subscription ownership also removes sources on release and uses weak recorder references in callbacks.
- Added application hide/show and window minimize/deminimize subscriptions. Event records now include PID and use cached window IDs when destruction makes the AX element unavailable. No titles or window contents are collected.
- Added explicit `subscriptionFailed` diagnostics and a `recorderReady` marker after initial setup. Observer/reference counts are attempted coverage, not proof of successful subscriptions. Apps can reject notifications, and launch-time retry/reconciliation remains open.
- Validation: debug build and all 26 core regressions pass. Read-only one-second recording smoke checks exit cleanly; applications report subscription errors that were previously silent. Controlled app-launch/window-create/destroy delivery, repeat-start/stop behavior, and popup/tab traces remain to be exercised. No native feasibility gate is claimed complete by this instrumentation change.

This recorder is not the live management registry and does not feed the lifecycle reducer. Fullscreen state still needs snapshot confirmation; a resize notification is insufficient. The app remains diagnostic-only.

## Increment 7: bounded recorder startup reconciliation

- Initial and newly launched applications receive three bounded subscription/enumeration retry passes, nominally at 1, 3, and 7 seconds. This retries observer creation and app/window subscriptions and discovers windows omitted during startup. AX work can delay the passes.
- Existing references are deduplicated; unresolved cached window IDs can be refreshed. Missing enumeration entries never imply closure. Application termination and recorder stop cancel pending retry tasks, including processes whose observer creation failed.
- `subscriptionRetry` marks attempted reconciliation, not successful delivery. Continuous reconciliation, controlled launch/termination and repeat-start/stop validation remain open.
- Validation: debug build and all 26 core regressions pass; editor diagnostics report no errors. An eight-second read-only recorder smoke run emitted one readiness marker and 236 retry-pass records and exited cleanly. Native-tab, popup, display and Space-transfer feasibility gates remain open. The app remains diagnostic-only.

## Increment 8: subscription retry deduplication

- Recorder subscriptions now retain successful notification registrations per observer and AX element. Startup reconciliation and repeated focus discovery skip confirmed registrations, while failed requests remain eligible for retry. `notificationAlreadyRegistered` also confirms coverage; it does not establish event delivery.
- Destroy notifications discard cached registration state for that element. Observer teardown releases the entire cache, so replacement observers must register afresh. Equal AX references share registration state without merging distinct elements or notification names.
- Added a platform test target and three regressions using synthetic AX application references and injected registration results. They cover successful-request deduplication, failure recovery, element/notification isolation, removal, and replacement-observer state. These tests make no live notification registrations and need no Accessibility permission.
- Validation: debug build, all 26 core tests and all three platform tests pass. Editor diagnostics report no errors. Controlled live launch/termination, repeated recorder start/stop, and native feasibility validation remain open. The app remains diagnostic-only.

## Increment 9: isolated recorder lifecycle regressions

- Added internal injection of the workspace notification center, initial application list, and diagnostic output sink. The public recorder still uses the real workspace and JSONL output; tests can exercise lifecycle handling without observing other applications.
- Added three platform regressions covering idempotent start/stop, restart without duplicate workspace delivery, release of a running recorder, and malformed workspace notifications. Synthetic termination events exercise callbacks without native AX registration or Accessibility permission.
- Validation: debug build, all 26 core tests and all six platform tests pass. These isolated tests validate workspace-listener lifecycle, not AX run-loop source cleanup or retry cancellation with attached processes. Controlled live launch/window-create/destroy/termination, native tabs, popup recovery, display ownership and Space-transfer gates remain open. The app remains diagnostic-only.

## Increment 10: bounded retry cancellation and cleanup

- Extracted recorder startup retry ownership into a main-actor helper while preserving the three 1/2/4-second delays. Completion, sleep failure, and early exit now release pending entries; previously an early exit could leave a completed task retained until stop or termination.
- PID cancellation, stop, and helper release cancel outstanding tasks. A token check prevents late completion from running cancelled work or removing a replacement schedule for the same PID. Recorder callbacks retain their owner weakly.
- Added four deterministic platform regressions with a controllable sleeper: exact pass limit and duplicate suppression, early-exit/error cleanup, cancellation followed by same-PID replacement, and stop/release cancellation. The sleeper deliberately resumes after cancellation to exercise stale-work protection without real delays or AX calls.
- Validation: debug build, all 26 core tests and all ten platform tests pass. These tests cover retry ownership independently of native processes. Live AX run-loop source cleanup, controlled launch/window-create/destroy/termination, native tabs, popup recovery, display ownership and Space-transfer gates remain open. The app remains diagnostic-only.

## Increment 11: controlled live recorder validation

- Added optional repeatable `record --bundle-id` filters across initial discovery and workspace launch/termination handling, with strict duration/argument parsing. JSON output now reaches pipes immediately, allowing a harness to launch interactions only after `recorderReady`.
- Added a disposable regular AppKit fixture and an opt-in `ruby scripts/check-ax-recorder.rb` check. The fixture is launched in the background, changes only its own window, and quits without opening/saving documents. Temporary bundle/logs are removed; only event counts are reported. Unit tests never launch it.
- Live check passed on the initial host with the existing CLI run loop: one launch, create, move, resize, minimize, restore, destroy and termination event, three retry passes, and clean recording end. Created/destroyed IDs match and are nonzero. No subscription failures were reported in the successful controlled capture.
- An accessory-app version completed all fixture actions but produced no workspace launch/termination events, including when tested with a full AppKit event loop. Newly launched accessory apps remain a discovery limitation. The final check uses a regular app and does not generalize its success to accessory apps or other applications; no event-loop change was retained.
- Added three option/filter regressions. The debug build and all 39 tests (26 core, 13 platform) pass. Native-tab grouping, popup recovery, independent displays, Space transfer, and native source teardown/restart validation remain open. The app remains diagnostic-only.

## Increment 12: native-tab structural evidence collection

- Added read-only `tab-evidence bundle.identifier` diagnostics for one application's AX window roots and structural relationships. Captures include query errors, role/subrole, boolean selection values, available attribute names, window IDs and capture-local graph references. Titles, labels, descriptions and string values are not queried. Traversal is bounded by depth 5, 128 nodes and a one-second per-app traversal budget plus an in-flight AX call; truncation is explicit.
- Extended the disposable fixture with eight native-tab stages and added `ruby scripts/check-native-tabs.rb [new-output.json]`. The harness validates the fixture's own merge/selection/detach/close state, checks process ownership and capture timing, and saves ground truth alongside AX captures without overwriting prior output. This is an investigation, not a grouping acceptance test.
- On the initial host, all eight native operations were confirmed and captures completed within their stages, but AX window enumeration succeeded with an empty array throughout. A separate key-window experiment did not change that result; its activation change was removed. The final report explicitly records inconclusive AX coverage. This does not establish that tabs are absent or unsupported in daily apps.
- A read-only Finder capture exercised the graph collector against an existing application and returned one nonstandard AX root (scroll area), not affirmative native-tab grouping evidence. Next inspect observer-supplied window references and real daily-app tab transitions; no grouping heuristic or management effect was enabled.
- Validation: debug build and all 39 existing regressions pass; editor diagnostics report no errors. Native-tab grouping, popup recovery, independent displays, Space transfer and native source teardown/restart gates remain open. Raw captures are kept in ignored local capture/build directories. The app remains diagnostic-only.

## Increment 13: observer-backed native-tab evidence

- Added opt-in `record --bundle-id identifier --tab-evidence`, restricted to one explicit app. A single recorder session now emits bounded structural samples roughly once per second, with separate enumerated and observer-supplied roots plus capture-start/completion uptime. Detailed graph reads may delay callbacks; this is not a performance mode.
- Updated the native-tab harness to start observation before fixture launch and retain the same session through all eight stages. Observer references survive disappearance from enumeration and are removed by confirmed destruction. Samples spanning a fixture transition remain inconclusive.
- The controlled persistent session exposes two enumerated/observed roots before merge, one enumerated and two observed roots during merge/selection, two enumerated roots after detach, one surviving root after active close, and zero after last close. All five harness checks pass: stage coverage, physical root identity, merged structure/selection, detached enumeration and confirmed destruction. No samples were truncated or crossed stage boundaries.
- `AXTabs` is available on a child `AXTabGroup`, not the window root. Two `AXTabButton` radio controls expose selection state, and the enumerated window ID follows the fixture's selected member. Both controls point back to the active window, so a direct inactive-member mapping is still missing. The difference from increment 12's empty one-shot enumeration is observed; its cause is not established.
- Added a regression for opt-in scope/argument validation. Debug build and all 40 tests (26 core, 14 platform) pass; editor diagnostics report no errors. Captures remain local and ignored. Daily-app native grouping and disambiguation between multiple containers, popup recovery, independent displays, Space transfer and native source teardown/restart remain release gates. No grouping heuristic, reducer wiring or window-management effect was enabled.

## Increment 14: multiple native-tab containers and independent enumeration checks

- Added an opt-in five-window `--multi` fixture: two independent native-tab pairs and an unrelated window, all with identical titles. It switches both groups, detaches a member, moves it into the other group (three tabs), closes the selected member, then closes all remaining windows. Ground-truth checks confirm membership, exact active-member closure and continued independence of the unrelated window.
- Generalized the harness's structural checks to validate each tab group's owner, tab count and selection against fixture ground truth. Physical observer roots and confirmed destruction are checked independently. No title/geometry association or production membership resolver was added.
- Single- and multiple-container captures pass stage coverage, physical root identity, tab-group ownership/selection and destruction checks. The five-window run retains five roots until active close, then four, then zero; the observed tab-group counts progress from two two-tab groups to one three-tab group and then one two-tab group. All captures remain within their stages and traversal limits.
- AX window enumeration returns an empty array throughout both latest runs. Enumerated representatives therefore fail their own explicit check while observer structure remains verified. This revises no earlier capture result and establishes no cause for the difference; enumeration alone is insufficient evidence of an empty layout.
- Validation: debug build and all 40 Swift regressions pass. Both live fixture modes were exercised; strengthened active-close/independent-window assertions were also checked against the completed captures. Direct inactive-member assignment, daily-app parity, popup recovery, independent displays, Space transfer and native source teardown/restart remain open. The app remains diagnostic-only.

## Increment 15: AX equality continuity and observed-selection bindings

- Added bounded diagnostic equality tokens for retained AX references in persistent tab captures. Each observer has a unique identity scope, retains at most 512 elements, never recycles its assigned tokens, reports exhaustion explicitly and releases its registry at teardown. Tokens use `CFEqual`; capture-local graph indices remain separate. They are not durable semantic tab IDs, especially after destruction/reuse or across scopes.
- The harness now compares each fixture group's token and ordered tab-control tokens through selection of the first member, the second member and back. It records selected-control bindings using the observed physical owner ID and verifies them against fixture ground truth. Missing tokens, changed scopes or exhausted/truncated samples make comparisons inconclusive.
- In two live multiple-container runs, both groups preserve their group/control equality tokens across the switches. Each selected control binds consistently to a distinct physical member, and selecting back restores the original binding. The final association checks pass independently for both groups, without identity-budget exhaustion. Observer structure, root identity and destruction checks still pass; enumerated representatives still fail independently.
- Added two platform regressions for equality/difference, scope separation, bounded capacity and preservation of known tokens after exhaustion. Debug build and all 42 tests (26 core, 16 platform) pass; editor diagnostics report no errors. Ruby syntax and physical-owner guards were verified, including against the completed capture.
- This supports association after observing selection in unchanged fixture groups only. Unvisited-member assignment, identity continuity through regrouping/destruction, daily-app parity, enumeration failures and the other native release gates remain open. No production association resolver, reducer integration or management effect was enabled; the app remains diagnostic-only.

## Increment 16: conservative diagnostic selection-association tracker

- Added an in-memory candidate tracker to persistent tab evidence. It learns only selected-control/physical-owner pairs; unvisited controls stay unresolved, and completeness requires every current control to have been visited. The AX adapter requires current root ownership, complete metadata and exactly one known selection. These candidates are not native-window classification or management authorization.
- Scope, group-set and ordered-control changes discard learned bindings. Incomplete evidence, group disappearance and confirmed window destruction invalidate learning without treating absent windows as closed. Duplicate/shared identities and conflicting physical owners fail closed and quarantine the observer until its scope changes. No deferred association replay is introduced.
- Added nine regressions covering partial learning, topology/order/scope/destruction resets, missing metadata, conflict quarantine, duplicate physical IDs/control tokens, graph ownership, selection ambiguity and native AX metadata types. The first live integration attempt exposed an Int32-vs-Int AX-result parsing mismatch; it is fixed and covered by a native AX/CFBoolean regression.
- Debug build and all 51 tests (26 core, 25 platform) pass. The corrected live five-window run passes all nine harness checks, including candidate soundness, visited-group completion, regrouping invalidation and final cleanup. Both groups are partial after learning one member, complete after visiting both, then partial/unavailable again after topology changes. AX enumeration succeeds in this capture; earlier empty captures remain unexplained and are not superseded as a general guarantee.
- Native-vs-content-tab classification, unvisited members, daily-app parity and the other platform release gates remain open. The candidate tracker is diagnostic-only and disconnected from the layout reducer and effect scheduling. No window-management behavior is enabled.

## Increment 17: content-tab negative control and explicit quarantine evidence

- Added `check-native-tabs.rb --content`: the five-window fixture now includes an ordinary two-item `NSTabView` in the independent window while exercising the two native groups. Ground truth confirms content selection 0→1→0→1 and no native membership for that window. Native/content separation in the harness uses fixture ground truth only, not a production app rule.
- The content controls expose the same `AXTabGroup`/`AXTabButton` roles as native tabs. Their selection values use numeric zero/one, so the collector now normalizes exactly those values for radio-button `AXValue`, records the encoding, and rejects other roles/attributes/numbers. `AXValue` is no longer queried on non-radio controls. A new regression covers numeric bounds, role/attribute scope, strings and CFBoolean behavior.
- Visiting both content controls points to the same physical window and triggers existing identity-conflict quarantine. Reports now expose retained `quarantined` state independently from current evidence status, with a regression confirming it survives missing metadata. A later `unavailable` capture does not clear the prior conflict.
- Debug build and all 52 tests (26 core, 26 platform) pass. The final mixed fixture passes all 13 harness checks: actual content AX visibility/selection, no complete content candidate, retained conflict quarantine, native structure, identity and cleanup. The native-only positive control still passes all nine checks and learns both groups. Earlier failed assertions distinguished unavailable metadata from retained quarantine; the final harness checks both explicitly.
- This validates conservative withholding for the controlled content-tab case, not a general native-vs-content classifier. The current diagnostic policy can withhold a whole mixed app; daily-app support, narrower ambiguity recovery, unvisited members and the other release gates remain open. No layout/reducer integration or window-management effects were enabled.

## Increment 18: isolate diagnostic group conflicts

- Physical-owner conflicts now quarantine every implicated group while unrelated groups continue learning. Shared or malformed AX identities still quarantine the entire observer. Collision checks include currently observed owners of already blocked groups and do not choose a winning claimant.
- Reports distinguish `scopeQuarantined`, retained `quarantinedGroups`, and per-candidate quarantine. Blocked candidates expose no bindings and cannot become complete. Group quarantine persists through missing evidence, disappearance, topology changes and destruction invalidation until observer replacement; normal topology changes still conservatively clear all learned bindings.
- Added three regressions for mixed-group learning, retained quarantine, cross-group collisions and observer-wide identity corruption. All 55 tests (26 core, 29 platform) pass; editor diagnostics and patch formatting are clean.
- The mixed live fixture passes all 15 checks, including complete learning of both native groups while only the content group is quarantined. The native-only positive control passes all nine checks. The harness now checks isolated quarantine explicitly and uses report schema 7.
- This closes the controlled mixed-group conflict-isolation gap. Whole-capture metadata failures still withhold learning; daily-app classification, unvisited members, popup recovery, displays, Spaces and lifecycle release gates remain open. No reducer integration or window-management effects were enabled.

## Increment 19: live unvisited-member withholding and recovery

- Added `check-native-tabs.rb --unvisited`, a disposable three-window native group with nine captured stages. Two members are selected first, then the third is visited and the earlier members revisited. The slower fixture runs for about 29 seconds; report schema is now 8.
- The first live run found that AppKit omits `AXValue` for the unvisited control. The existing complete-metadata requirement correctly withholds the entire candidate, even though all three physical windows are already known. Initial assertions expecting partial learning failed; the final harness explicitly verifies missing-value withholding rather than weakening the parser.
- Selecting the third member starts fresh with only that observed binding. Revisiting the first two completes the same group and ordered controls in the same observer scope. Closing a member clears the previous bindings. The final live fixture passes all 12 checks, including physical inventory, selection structure, missing-value withholding, fresh learning, completion and cleanup.
- Debug build and all 55 tests (26 core, 29 platform) pass. The existing mixed native/content fixture still passes all 15 checks. Editor diagnostics and Ruby syntax checks are clean. Production association logic is unchanged; no unvisited binding is inferred or replayed.
- Controlled unvisited-member behavior is now validated. Daily-app classification and unvisited discovery, whole-capture metadata failures, popup recovery, displays, Spaces and remaining lifecycle release gates stay open. No window-management effects were enabled.

## Increment 20: native source ownership and controlled recorder restart

- Extracted native run-loop source ownership with idempotent removal and release cleanup. Recorder stop reports actual source-removal results before releasing native observers, and clears workspace listeners/retries. The CLI includes teardown evidence on recording end.
- Added opt-in `record --restart-after seconds` with strict finite, positive, in-duration validation. The same recorder stops and starts once, emitting new readiness and explicit restart evidence. Native-tab `--restart` uses a wide quiet interval around replacement and report schema 9.
- The controlled run passes all 14 required checks: a previously complete native pair becomes partial under a new identity scope, sources are removed, readiness is not duplicated, and each physical window creates/destroys once. `physicalInventoryComplete` is separately false: a fresh observer initially sees only the selected representative. No old references or bindings are replayed to hide this rediscovery limitation. An initial timing-sensitive run was inconclusive; the final fixture separates selection-back, restart and capture.
- Added native-CFRunLoop tests for removal/replacement, release cleanup and no delivery of queued callbacks after removal, plus restart-option validation. Distinct synthetic source contexts are required because empty CFRunLoopSource contexts compare equal. No Accessibility registration occurs in these isolated tests.
- Debug build and all 59 tests (26 core, 33 platform) pass. The original live launch/move/resize/minimize/restore/close recorder check also passes. Editor diagnostics and patch formatting are clean.
- This validates controlled native-source teardown/restart and preserves diagnostic-only operation. Daily-app recovery, inactive-member rediscovery, metadata/classification gaps and other platform release gates remain open.

## Increment 21: scoped popup policy evidence and unknown presentation state

- Added bounded `window-evidence identifier` and `record --window-evidence` for one explicit app. Reports preserve enumeration/observer provenance, direct window/sheet children, roles, policy facts, query errors and per-app focus identities. No text or geometry values are read. Traversal has explicit depth/node/child/time limits and truncation.
- Fullscreen/minimized metadata is now optional in window facts. Otherwise eligible windows remain pending when those reads are unavailable; snapshot schema 2 uses null instead of silently substituting false. Added missing-state classification/serialization and option-scope regressions; recording options are Sendable for timer capture.
- Added a disposable six-stage document/nonactivating-panel/sheet fixture and `check-popups.rb`. All 12 live checks pass: transient exclusion, preserved document eligibility/observation, continued move events after dismissal, distinct sheet focus vs document owner, per-app focus return after sheet dismissal, close cleanup, native teardown and no content values.
- The panel exposes AXSystemFloatingWindow; the sheet exposes AXSheet without a subrole. Its focused UI owner points to the document while the focused-window ID identifies the sheet. The app stays inactive, and document-focus return after the nonactivating panel is unproven. This does not close OS active-focus, cross-display, Control Center, context-menu, file-panel or original-popup recovery gates.
- Debug build and all 62 tests (28 core, 34 platform) pass; editor diagnostics, Ruby syntax and patch formatting are clean. The live popup check passes twice. Existing toolchain linker-path warnings remain nonfatal.
- Production remains diagnostic-only, with no reducer wiring or window-management effects.

## Increment 22: isolate missing selection within known tab groups

- Missing/ambiguous selection now withholds only a group whose structure, tokens and physical ownership are otherwise complete. `selectionKnown` and `unavailableGroups` make that state explicit; all its bindings clear immediately and recovery starts fresh. Unrelated groups keep learning under unchanged topology.
- Current physical owners of unavailable groups still participate in collision detection. Shared identity corruption remains observer-wide quarantine. Unknown structure/control shape/ownership, identity exhaustion and capture truncation still withhold the whole capture; topology changes and confirmed destruction still clear all learned bindings conservatively.
- Added four regressions for isolated clearing/recovery, current-owner collisions, shared control tokens, and parser-to-tracker behavior with unknown ownership. All 66 tests (28 core, 38 platform) pass; editor diagnostics are clean.
- Added six-window `--partial` fixture and report schema 10. All ten required live checks pass: the visited two-tab group completes while the three-tab group with an unvisited member retains zero bindings. `enumeratedRepresentatives` is separately false because AX enumeration is empty; physical observer roots and group structure are complete. No absent-window or title/geometry inference is used.
- Unvisited-member recovery and mixed content-tab quarantine also pass all required checks after the change; both separately report empty AX enumeration. Ruby syntax and patch formatting are clean.
- Native-tab classification, unknown structural metadata, daily-app unvisited discovery and other platform release gates remain open. No window-management effects or reducer integration were enabled.

## Increment 23: repeated diagnostics and visible restart rediscovery failures

- Added `check-diagnostics.rb --cycles 1..5 [new-output-directory]` to run all eight controlled modes sequentially. It preserves separate reports/logs, updates an aggregate summary after every fixture and exits nonzero on required failures. Native enumeration and restart inventory gaps remain explicit informational checks; structural/event/cleanup failures are not waived. The recorder harness can now save a fresh JSON report separately from build output.
- Two complete rounds against production revision 0ec5ad0 ran all 16 fixture cases in about seven minutes. Fourteen passed all required checks. Both restart cases correctly remained inconclusive: empty successful AX enumeration left the replacement observer with zero existing window references, preventing tab-structure/reset verification and later destruction delivery. Native source removal and readiness counts still passed in both cases. The aggregate runner returned nonzero and retained the failed reports.
- This supersedes any implication that the earlier single successful restart fixture established full restart recovery. Source ownership and inactive-window rediscovery are separate concerns. Missing references are not closed windows and are not repaired by replaying old-scope state.
- All non-restart modes passed twice: recorder delivery, native pair, multiple groups, partial selection, content-tab withholding, unvisited recovery and popup policy. Raw reports/logs remain ignored local captures. No release gate or management effect was enabled.

## Increment 24: reject callbacks from previous recorder runs

- A deterministic test retained an old workspace termination callback, stopped/restarted the recorder, then delivered that callback. The previous running-flag check accepted it into the new run; the test reproduced extra event records before the fix.
- Each start now creates a private run token, invalidated on stop. Workspace closures and native subscriptions carry their originating token and reject old-run delivery before mutating state or emitting events. Current-run callbacks still work, and retries retain their existing cancellation tokens.
- All 67 regressions (28 core, 39 platform) pass in both debug and release, including the previously failing old-callback case. The live baseline recorder check still passes. Native restart metrics now distinguish duplicate delivery from complete create/destroy coverage; missing destruction is not labeled as duplication.
- A final native restart capture after the fix passes every required check, including fresh partial learning, unique/complete window-event delivery and source removal. Its initial physical inventory and enumerated-representative checks still report incomplete coverage. This single successful recovery does not negate the two soak failures or establish a cause for differing rediscovery behavior.
- This fixes stale-run acceptance, not the separate empty-enumeration rediscovery gap found by the soak. Production remains diagnostic-only and platform release gates remain open.

## Increment 25: fresh focused/main window discovery

- Startup/retry reconciliation now reads AXFocusedWindow and AXMainWindow alongside AXWindows. Each fresh reference must match the observer PID and expose AXWindow or AXSheet; CF-equal references deduplicate across sources before subscribing. No prior observer references or learned bindings are carried forward.
- Added `windowDiscovery` diagnostics with query errors, accepted source provenance and rejected-reference counts. Native fixture schema 11 preserves discovery passes, making channel availability inspectable rather than attributing a successful restart to the fallback without evidence.
- Three isolated regressions cover empty-enumeration fallback, equality/provenance deduplication, foreign/missing PID, missing/non-window roles, sheet references and wholly absent input. All 70 regressions (28 core, 42 platform) pass in debug and release; editor diagnostics and patch formatting are clean.
- Two live native restart runs pass all required checks while initial physical inventory remains incomplete. In the second run, all eight discovery passes show AXFocusedWindow/AXMainWindow returning -25212; every accepted reference came from AXWindows. Thus this host did not affirmatively exercise the fallback. The unit checks establish its filtering behavior, not daily-app support or a fix for the prior empty-enumeration failures.
- Restart/inactive-member rediscovery remains open when all fresh channels are unavailable. The app remains diagnostic-only, with no layout integration or window-management effects.

## Validation on the initial host

### Revalidation after increment 5 (2026-11-06 local time)

- The full debug build and all 26 Swift Testing regressions in three suites pass, including the 15 tests added in increments 2–5. This supersedes the unexecuted-test limitations recorded in those implementation sessions.
- The installed Command Line Tools are functional. Earlier failures to resolve the active developer directory occurred inside the restricted execution sandbox; running `./scripts/swift.sh test` with approved access outside that sandbox succeeded. No toolchain installation or global developer-directory change was necessary.
- Existing toolchain framework/library search-path warnings remain nonfatal. This run validates the debug build and core tests, not release signing or notarization.
- A fresh read-only debug snapshot confirms Accessibility trust and available Space queries on macOS 26.7.2 / arm64. One built-in display is connected, and separate Spaces remains disabled. Sampled fullscreen and nonstandard windows were excluded; this snapshot does not establish popup recovery, native-tab grouping, transfers, or independent-display behavior.
- Snapshot discovery took about 3.28 seconds. This is discovery duration, not input-to-window-motion latency. No window titles were requested, and no raw capture was committed.

Next integration priorities remain affirmative native-tab evidence, popup interaction traces, and confirmed display/Space ownership. The app remains diagnostic-only until the feasibility gates are verified.

### Original increment 1 validation

- Swift 6.4 / Command Line Tools; macOS 26.7.2, arm64. The SDK is macOS 27; deployment target is macOS 14. Older OS support has not been exercised.
- 11 Swift Testing regressions pass. Editor diagnostics report no errors.
- Release app builds and is locally ad hoc signed. This is not a notarized release.
- Read-only native discovery reports AX permission available, Space topology available and window/Space membership resolved for accessible windows.
- One built-in display is connected; “Displays have separate Spaces” is disabled. The independent-display release gate cannot be validated in this setup. No settings were changed.
- Initial cold-ish debug discovery took approximately 2.6 seconds across running apps. It is not a keystroke-latency benchmark; windows on inactive Spaces can be absent from public AX discovery.
- A release cached-layout microbenchmark with 50 windows and 1,000 iterations measured p50 about 0.0048 ms and p95 about 0.0055 ms. This excludes AX traffic, animation, input and physical rendering; it establishes no end-to-end performance advantage.
- The Swift wrapper works around stale private PackageDescription interfaces in the installed CLT and explicitly loads its bundled Testing macro plugin. Toolchain framework search-path warnings remain, but builds complete. No system toolchain files were edited.
