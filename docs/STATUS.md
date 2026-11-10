# Implementation status

Current state and resume instructions only. The chronological increment log (increments 1–62) and the original initial-host validation are in [HISTORY.md](HISTORY.md); those entries describe evidence at their original dates.

## Current checkpoint: 2026-11-09

Includes increment 62. Paperi is a diagnostic/prototype application: general user-window management is disabled, no global shortcuts are registered, and menu/snapshot/record stay inactive/read-only as applicable. Route: [ordinary-window path followed early by one native-tab app](../plan.md#agreed-implementation-order--2026-11-08), informed by the [pinned-source audit](REFERENCE-AUDIT.md).

### Capability matrix

| Capability | Disposable fixture | Real apps | Remaining limits |
| --- | --- | --- | --- |
| Native create/close → reducer → confirmed AX effects | Verified, debug/release | Terminal verified (`check-terminal-tabs.rb --session`) | Owned test windows only |
| Observed resize, width commands, focus suppression | Verified | Terminal measured cell-grid resize verified (`--resize`) | Per-app focus; panel focus suppresses commands without replay |
| Interactive preview (`paperi preview-fixture`) | Verified (`probe-preview-input` passes 12/12: lazy tab merge/switch/detach, width grow/shrink, stack/unstack, stop/restore) | — | Local AppKit controls/key equivalents (Narrower/Wider/Stack/Unstack/Next Space/Stop) only |
| Scoped session: frontmost ownership, stable slots, stop-ticket invalidation | Verified | Terminal session uses its guards | App/Space scoped; unknown membership is rejected |
| Controlled stop and geometry restoration | Verified | Terminal position and width restored | Not crash or abrupt-exit recovery |
| Native-tab membership & tab-bar-free singleton detection (external AX) | Verified (`requireComplete: true/false`, including `-25200` unvisited `AXValue`) | Terminal and Finder verified (`check-finder-documents.rb --new-tab`, 7/7 checks); Preview untested | Active-first mode (`requireComplete: false`) admits and tiles the active tab immediately; strict mode (`requireComplete: true`) still requires visiting all tabs |
| Native-tab lifecycle: switch, detach, re-merge, new member, active/last close | Verified, debug/release (`allowLazyUnvisited: true/false`) | Terminal verified in sustained shared session (`--session`, 12/12 checks) | `allowLazyUnvisited: true` reconciles newly clicked background tabs in place and infers known merged windows without clicking inactive tabs |
| Stacked-column native reconciliation & slurp/barf | Verified live (`paperi probe-preview-input`) and in unit tests (`ScopedLayoutSession.reconcileTabs`, `NativeTabTopologyTests`) | Not attempted | Preserves column index, row order, width and stack weights across tab switch/detach/merge/growth/close |
| Popups/transients | App utility panel and sheet | OS, Control Center, cross-display untested | — |
| Cross-Space container transfer | Verified end-to-end in debug/release (`paperi probe-space-session`, 12/12 checks; `PaperiSpaceProbe --backend mission-control`) | Not attempted | Direct SkyLight compatibility path fails; Mission Control app-grouping (`expose-group-apps = 1`) clusters multiple untabbed windows of one app on crowded Spaces |
| Multi-display & multi-Space coordinator | Verified live across user Spaces (`paperi probe-space-session`) and in unit tests (`DisplaySpaceCoordinatorTests`, including negative-origin secondary monitor and 1-based Space numbering) | Single-display Spaces enumerated live | Physical multi-monitor live hardware not connected on this host ("Displays have separate Spaces" disabled) |
| Global keyboard routing | Disabled | — | Deprioritized per user direction |
| Baseline, performance, soak | Not started | — | Release gates |

### Tests and evidence

- Increment 62:
  - Wired lazy native-tab reconciliation (`allowLazyUnvisited: true`), stacked-column `slurp`/`barf`, and post-transfer Space reassignment (`ScopedLayoutSession.reassignSpace`) into `paperi preview-fixture` (`LifecycleProbe.swift`, `Tools/AXFixture/main.swift`).
  - Added `TabSelectionEvidence.lazySelectedControl(for:in:)` (`SelectionAssociations.swift`) so when macOS AppKit returns `AXError.failure (-25200)` for an unvisited background tab's `AXValue` while the active tab button reports `AXValue == true`, active-first admission and lazy topology reconciliation still resolve the active tab without clicking the background tab.
  - Live `paperi probe-preview-input` (`captures/preview-input-increment62-pass.json`) passes all 12/12 checks (lazy tab merge before visiting the background tab, tab switch A→B→A, tab detach back to 2 columns, width `grow`/`shrink`, stacked-column `slurp`/`barf` with 6 confirmed AX writes each, and full frame restoration on stop). All 122 Swift regressions pass in debug and release.
- Increment 61:
  - Added active-first tab admission (`NativeTabMembership.inspect(_:requireComplete: false)` and `ScopedLayoutSession.admitTabs(_:allowActiveOnly: true)` / `DisplaySpaceCoordinator.admitTabs(_:allowActiveOnly: true)`) and lazy unvisited tab reconciliation (`NativeTabTopology.inspect(_:allowLazyUnvisited: true)` and `DisplaySpaceCoordinator.reconcileTabs`), allowing tabbed windows with unvisited background tabs to be tiled immediately, switching representative in place when a background tab is clicked, and inferring already-managed windows merged into an unvisited tab. All 122 Swift regressions (32 core, 90 platform) pass in debug and release.
- Increment 60:
  - End-to-end cross-Space 2-tab session probe (`paperi probe-space-session`) passes all 12 checks in both debug (`captures/space-session-increment60-tabs-debug3.json`) and release (`captures/space-session-increment60-tabs-release.json`): learns a 2-tab native container externally, admits it into `DisplaySpaceCoordinator` on Space `1`, transfers it via Mission Control (`SpaceTransfer.moveWindowViaMissionControl`) and `DisplaySpaceCoordinator.transferContainer` to Space `378` with confirmed AX placement, transfers it back to Space `1` with confirmed AX placement while preserving the logical slot ID and both tab members, and restores the original frame on stop.
  - `paperi probe-preview-input` passes all 11 checks (`captures/preview-input-increment60-debug.json`), and all 120 Swift regressions pass in debug and release.
- Increment 59:
  - Sustained shared-session Terminal native-tab lifecycle (`ruby scripts/check-terminal-tabs.rb --session captures/terminal-session-increment59`) passes all 12 checks (`tabSupport: "verifiedInOwnedSession"`, `cleanup: "closed"`).
  - Finder native-tab membership & singleton detection (`ruby scripts/check-finder-documents.rb --new-tab captures/finder-tabs-increment59`) passes all 7 checks (`sharedMembershipVerified: true`, `ownedSingletonsConfirmed: true`).
- Increment 58: `PaperiSpaceProbe --backend mission-control` passes outbound (`1`→`378`) and return (`378`→`1`) membership and active-Space follow in both debug and release.
- Increment 57: debug Terminal resize run passes eight baseline/membership/geometry/column-restoration checks (`captures/terminal-resize-increment57-final/summary.json`).
- The last full ten-mode integrated cycle passed 9/10 and has not been repeated. Intermittent AX role/reference and restart rediscovery failures remain open.

### Next

Validate Preview.app native-tab compatibility, exercise stacked-column native-tab reconciliation in a live AppKit fixture probe, and investigate expanding Mission Control application clusters when `expose-group-apps = 1` is enabled for multi-window untabbed apps. Physical/global keyboard routing stays deprioritized; abrupt-exit recovery, OS/cross-display popup recovery, physical multi-monitor validation and baseline/soak measurements remain release gates.

## Handoff — 2026-11-09

Implementation through increment 60 validates:
- End-to-end cross-Space 2-tab container transfer, per-Space `ScopedLayoutSession` placement confirmation, and frame restoration (`paperi probe-space-session`, 12/12 checks in debug and release).
- Sustained shared-session native-tab lifecycle on owned Terminal windows (`paperi probe-terminal-session`, 12/12 checks).
- Finder native-tab membership learning alongside tab-bar-free singleton detection (`check-finder-documents.rb --new-tab`, 7/7 checks).
- Stacked-column native-tab reconciliation (`ScopedLayoutSession.reconcileTabs`, `slurpFocused`, `barfFocused`) and multi-display/multi-Space container coordination (`DisplaySpaceCoordinator`).

### Resume here

1. Exercise stacked-column native-tab reconciliation in a live AppKit fixture probe (combining `slurp`/`barf` with native tab switch/detach/merge/close).
2. Validate Preview.app native-tab compatibility using the shared `nativeTabEvidence` and `singletonCandidates` path.
3. For untabbed multi-window apps on crowded Spaces when `com.apple.dock` `expose-group-apps = 1` is active, evaluate expanding the app cluster in Mission Control before dragging so individual untabbed windows move without pulling same-app siblings.

### Code and validation entry points

| Purpose | Entry point |
| --- | --- |
| Shared session, stacked-column reconciliation, slurp/barf and stop guards | [ScopedLayoutSession.swift](../Sources/PaperiPlatform/ScopedLayoutSession.swift), [ScopedLayoutSessionTests.swift](../Tests/PaperiPlatformTests/ScopedLayoutSessionTests.swift), [NativeTabTopologyTests.swift](../Tests/PaperiPlatformTests/NativeTabTopologyTests.swift) |
| Multi-display and multi-Space session coordinator & live Space transfer | [DisplaySpaceCoordinator.swift](../Sources/PaperiPlatform/DisplaySpaceCoordinator.swift), [SpaceTransfer.swift](../Sources/PaperiPlatform/SpaceTransfer.swift), [DisplaySpaceCoordinatorTests.swift](../Tests/PaperiPlatformTests/DisplaySpaceCoordinatorTests.swift) |
| External membership learning, singleton inspection and topology reconciliation | [NativeTabMembership.swift](../Sources/PaperiPlatform/NativeTabMembership.swift), [NativeTabTopology.swift](../Sources/PaperiPlatform/NativeTabTopology.swift), [SelectionAssociations.swift](../Sources/PaperiPlatform/SelectionAssociations.swift) |
| Working sustained AppKit fixture | [NativeTabProbe.swift](../Sources/PaperiPlatform/NativeTabProbe.swift), [check-native-tabs.rb](../scripts/check-native-tabs.rb) |
| Terminal sustained session, placement and resize probes | [TerminalPlacementProbe.swift](../Sources/PaperiPlatform/TerminalPlacementProbe.swift), [check-terminal-tabs.rb](../scripts/check-terminal-tabs.rb) |
| Finder native-tab and singleton discovery harness | [check-finder-documents.rb](../scripts/check-finder-documents.rb) |
| Cross-Space transfer probe (`skylight`, `mission-control`, `drag-switch`) | [Tools/SpaceProbe/main.m](../Tools/SpaceProbe/main.m) |
| Commands, prerequisites and broader validation modes | [README](../README.md), [feasibility protocol](FEASIBILITY.md), [implementation plan](../plan.md) |

### Unresolved items to preserve

- Every native member must be visited before complete membership can be learned, including after topology changes. Do not replace this limitation with inferred membership.
- Intermittent AX reference/role failures and restart rediscovery remain open; the last full ten-mode cycle was 9/10 and has not been repeated. Focused passes do not supersede those failures.
- Direct SkyLight Space transfer fails on macOS 26.7.2 on this host and the newer bridged entry point is absent; the Mission Control drag/follow path works in the disposable probe, while live session/tab-container transfer transactions across Spaces remain to be wired into the runtime coordinator.
- Abrupt-exit recovery, broader popup/physical multi-display ownership, global keyboard routing, real baseline/performance measurements and daily-use soak remain release work. Controlled stop/restoration is not crash recovery.

Commit validated milestones autonomously per the [commit policy](../plan.md#commit-checkpoints). Keep raw captures/scratch out of commits and preserve unrelated changes. Historical increments in [HISTORY.md](HISTORY.md) describe evidence at their original dates; this handoff and the current checkpoint are the resume instructions.
