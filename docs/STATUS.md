# Implementation status

Current state and resume instructions only. The chronological increment log (increments 1–58) and the original initial-host validation are in [HISTORY.md](HISTORY.md); those entries describe evidence at their original dates.

## Current checkpoint: 2026-11-09

Includes increment 58. Paperi is a diagnostic/prototype application: general user-window management is disabled, no global shortcuts are registered, and menu/snapshot/record stay inactive/read-only as applicable. Route: [ordinary-window path followed early by one native-tab app](../plan.md#agreed-implementation-order--2026-11-08), informed by the [pinned-source audit](REFERENCE-AUDIT.md).

### Capability matrix

| Capability | Disposable fixture | Real apps | Remaining limits |
| --- | --- | --- | --- |
| Native create/close → reducer → confirmed AX effects | Verified, debug/release | Not attempted | Two newly created non-tabbing windows; neighbor/survivor reflow |
| Observed resize, width commands, focus suppression | Verified | Not attempted | Per-app focus; panel focus suppresses commands without replay |
| Interactive preview (`paperi preview-fixture`) | Verified, 60-second run | — | Local AppKit controls/key equivalents only; physical keyboard and expiry not separately exercised |
| Scoped session: frontmost ownership, stable slots, stop-ticket invalidation | Verified | Terminal probes use its guards | App/Space scoped; unknown membership is rejected |
| Controlled stop and geometry restoration | Verified | Terminal position and width restored | Not crash or abrupt-exit recovery |
| Native-tab membership learning (external AX) | Verified | Terminal verified; Finder blocked by mixed AXWindow/AXScrollArea roots; Preview untested | Every member must be visited, including after topology changes |
| Native-tab lifecycle: switch, detach, re-merge, new member, active/last close | Verified, debug/release | Not attempted | Atomic reconciliation keeps slot/width; incomplete topology withholds writes until relearned |
| Terminal guarded effects | — | Position translation; measured cell-grid width resize/restore (debug only) | UUID-tagged new idle tabs only; no sustained shared session |
| Stacked-column native reconciliation | Unverified | Unverified | — |
| Popups/transients | App utility panel and sheet | OS, Control Center, cross-display untested | — |
| Cross-Space transfer | Mission Control drag/follow round trip verified, debug/release (`PaperiSpaceProbe --backend mission-control`) | Not attempted | Direct SkyLight compatibility path fails; `drag-switch` unsupported here because system Move-a-space shortcuts (`79`/`81`) are disabled; session/tab-container wiring ahead |
| Multi-display ownership | Not testable on this host | — | One built-in display; "Displays have separate Spaces" disabled |
| Global keyboard routing | Disabled | — | Low priority until tabs, Spaces and multi-display work |
| Baseline, performance, soak | Not started | — | Release gates |

### Tests and evidence

- Increment 58: `PaperiSpaceProbe --backend mission-control` passes outbound (`1`→`378`) and return (`378`→`1`) membership and active-Space follow in both debug and release (`captures/space-probe-mission-control-debug.json`, `captures/space-probe-mission-control-release.json`). `--backend drag-switch` reports `unsupported` (exit 2) because symbolic hotkeys `79`/`81` are disabled on this host (`captures/space-probe-drag-switch-final.json`).
- Increment 57: all 116 Swift regressions pass in debug and release (32 core, 84 platform). The debug Terminal resize run passes eight baseline/membership/geometry/column-restoration checks.
- Increment 54: debug and release demo growth runs each pass 17 checks. Earlier native lifecycle, stop/restoration and content/unvisited controls are recorded in [HISTORY.md](HISTORY.md).
- Finder: two disposable-folder documents are discovered with correct physical IDs and classified eligible. A scoped New Tab exposes two AXTabButton controls, both referring to the active window. No Finder geometry or preference changes are performed; cleanup targets recorded test IDs only.
- The last full ten-mode integrated cycle passed 9/10 and has not been repeated. Intermittent AX role/reference and restart rediscovery failures are unresolved; passing focused repeats do not close them.

### Next

Connect sustained shared-session lifecycle management to the owned Terminal group, then Preview and Finder compatibility, including selection-driven relearning and intermittent AX-reference recovery. General app admission, stacked-column reconciliation, physical/global keyboard routing, abrupt-exit recovery, OS/cross-display popup recovery, display ownership, Space transfer and baseline/soak measurements remain release gates.

## Handoff — 2026-11-09

Implementation is committed through `8151f14` (increment 57); the working tree was clean before this documentation review. The project has a working disposable ordinary-window preview and externally observed native-tab lifecycle in the AppKit fixture. It is still a diagnostic/prototype application, not ready for general user-window management. Progress follows the agreed route, but real-app lifecycle acceptance and the release gates remain open. No sustained Terminal session work has started after increment 57.

### Resume here

1. Extend the exact-owned Terminal harness into a sustained session using the shared session and native-tab adapter. Keep UUID-tagged, newly created idle test tabs as the only writable scope; retain frontmost, identity, presentation and positive single-Space guards before effects. Do not use test tags or scripted tab lists to infer adapter membership.
2. First prove switching A→B→A in one session preserves the logical slot and preferred width while fresh selected-representative observations drive confirmed geometry. Incomplete or changed topology must suspend writes until all members are visited and membership is relearned.
3. Extend that session through detach/remerge, new-member admission, active closure and last closure. Require creation evidence for admission, destruction evidence for closure, consistent slot/width reconciliation, confirmed geometry and guarded stop/restoration/cleanup. Record failures as well as passes; a standalone placement/resize probe does not satisfy this milestone.
4. Validate focused debug/release regressions and the new owned-window native sequence, then commit the coherent result. After Terminal lifecycle acceptance, test Preview and resolve Finder association compatibility before widening admission. Keep global keyboard management disabled until its own scope/recovery gates pass.

### Code and validation entry points

| Purpose | Entry point |
| --- | --- |
| Shared session, command ownership, reconciliation and stop guards | [ScopedLayoutSession.swift](../Sources/PaperiPlatform/ScopedLayoutSession.swift) and [tests](../Tests/PaperiPlatformTests/ScopedLayoutSessionTests.swift) |
| External membership learning and topology reconciliation | [NativeTabMembership.swift](../Sources/PaperiPlatform/NativeTabMembership.swift), [NativeTabTopology.swift](../Sources/PaperiPlatform/NativeTabTopology.swift) |
| Working sustained fixture to reuse as the integration reference | [NativeTabProbe.swift](../Sources/PaperiPlatform/NativeTabProbe.swift), [check-native-tabs.rb](../scripts/check-native-tabs.rb); growth mode covers new-member admission |
| Terminal ownership/effects and current disposable harness | [TerminalPlacementProbe.swift](../Sources/PaperiPlatform/TerminalPlacementProbe.swift), [check-terminal-tabs.rb](../scripts/check-terminal-tabs.rb) |
| Cross-Space transfer probe (`skylight`, `mission-control`, `drag-switch`) | [Tools/SpaceProbe/main.m](../Tools/SpaceProbe/main.m) |
| Commands, prerequisites and broader validation modes | [README](../README.md), [feasibility protocol](FEASIBILITY.md), [implementation plan](../plan.md) |

Latest saved evidence was rechecked during this handoff; no new native effects or Swift tests were run for this documentation-only review:

- `.build/test-increment57-debug-final.log` and `.build/test-increment57-release-final.log`: each contains passing 84-platform and 32-core test runs (116 per configuration).
- `captures/terminal-resize-increment57-final/summary.json`: all eight checks true, `sharedMembershipVerified: true`, cleanup `closed`, and deliberately `tabSupport: unverified`. The validated sequence is 100→104→100 columns and 720→748→720 points on each A→B→A effect. Native effects were run in debug, not release.
- Captures and build logs are ignored local evidence, not committed deliverables; a fresh checkout must regenerate them. Use a new output directory for each harness run. Existing commands: `./scripts/swift.sh test`, `./scripts/swift.sh test -c release`, and `ruby scripts/check-terminal-tabs.rb --resize captures/<new-run-name>`. Native harnesses require a GUI session, Accessibility and Terminal/System Events automation access. Restricted-shell `xcode-select` failures have previously been sandbox artifacts; do not infer that the host toolchain needs reinstalling.

### Unresolved items to preserve

- Every native member must be visited before complete membership can be learned, including after topology changes. Do not replace this limitation with inferred membership.
- Intermittent AX reference/role failures and restart rediscovery remain open; the last full ten-mode cycle was 9/10 and has not been repeated. Focused passes do not supersede those failures.
- Finder's mixed AXWindow/AXScrollArea roots still block association acceptance; Preview and stacked-column native reconciliation remain unverified.
- Direct SkyLight Space transfer fails on macOS 26.7.2 on this host and the newer bridged entry point is absent; the Mission Control drag/follow path works in the disposable probe, while live session/tab-container transfer transactions remain open.
- Abrupt-exit recovery, broader popup/display/Space ownership, global keyboard routing, real baseline/performance measurements and daily-use soak remain release work. Controlled stop/restoration is not crash recovery.

Commit validated milestones autonomously per the [commit policy](../plan.md#commit-checkpoints). Keep raw captures/scratch out of commits and preserve unrelated changes. Historical increments in [HISTORY.md](HISTORY.md) describe evidence at their original dates; this handoff and the current checkpoint are the resume instructions.
