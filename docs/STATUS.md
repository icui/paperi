# Implementation status

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
