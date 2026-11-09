# Implementation status

Current state and resume instructions only. The chronological increment log (increments 1–59) and the original initial-host validation are in [HISTORY.md](HISTORY.md); those entries describe evidence at their original dates.

## Current checkpoint: 2026-11-09

Includes increment 59. Paperi is a diagnostic/prototype application: general user-window management is disabled, no global shortcuts are registered, and menu/snapshot/record stay inactive/read-only as applicable. Route: [ordinary-window path followed early by one native-tab app](../plan.md#agreed-implementation-order--2026-11-08), informed by the [pinned-source audit](REFERENCE-AUDIT.md).

### Capability matrix

| Capability | Disposable fixture | Real apps | Remaining limits |
| --- | --- | --- | --- |
| Native create/close → reducer → confirmed AX effects | Verified, debug/release | Terminal verified (`check-terminal-tabs.rb --session`) | Owned test windows only |
| Observed resize, width commands, focus suppression | Verified | Terminal measured cell-grid resize verified (`--resize`) | Per-app focus; panel focus suppresses commands without replay |
| Interactive preview (`paperi preview-fixture`) | Verified, 60-second run (`probe-preview-input` passes 11/11) | — | Local AppKit controls/key equivalents (Narrower/Wider/Stack/Unstack/Stop) only |
| Scoped session: frontmost ownership, stable slots, stop-ticket invalidation | Verified | Terminal session uses its guards | App/Space scoped; unknown membership is rejected |
| Controlled stop and geometry restoration | Verified | Terminal position and width restored | Not crash or abrupt-exit recovery |
| Native-tab membership & tab-bar-free singleton detection (external AX) | Verified | Terminal and Finder verified (`check-finder-documents.rb --new-tab`, 7/7 checks); Preview untested | Every tab member must be visited, including after topology changes |
| Native-tab lifecycle: switch, detach, re-merge, new member, active/last close | Verified, debug/release | Terminal verified in sustained shared session (`--session`, 12/12 checks) | Atomic reconciliation keeps slot/width; incomplete topology withholds writes until relearned |
| Stacked-column native reconciliation & slurp/barf | Verified (`ScopedLayoutSession.reconcileTabs`, `NativeTabTopologyTests`) | Not attempted | Preserves column index, row order, width and stack weights across tab switch/detach/merge/growth/close |
| Popups/transients | App utility panel and sheet | OS, Control Center, cross-display untested | — |
| Cross-Space transfer | Mission Control drag/follow round trip verified, debug/release (`PaperiSpaceProbe --backend mission-control`); `DisplaySpaceCoordinator.transferContainer` verified in unit tests | Not attempted | Direct SkyLight compatibility path fails; `drag-switch` unsupported here because system Move-a-space shortcuts (`79`/`81`) are disabled |
| Multi-display & multi-Space coordinator | Verified in unit tests (`DisplaySpaceCoordinatorTests`, including negative-origin secondary monitor and 1-based Space numbering) | Single-display Spaces enumerated live | Physical multi-monitor live hardware not connected on this host ("Displays have separate Spaces" disabled) |
| Global keyboard routing | Disabled | — | Deprioritized per user direction |
| Baseline, performance, soak | Not started | — | Release gates |

### Tests and evidence

- Increment 59:
  - Sustained shared-session Terminal native-tab lifecycle (`ruby scripts/check-terminal-tabs.rb --session captures/terminal-session-increment59`) passes all 12 checks (`admittedInitialPair`, `switchedRepresentativesInOneSlot`, `newMemberAdmitted`, `growthPreservedLogicalSlot`, `activeClosurePreservedSlot`, `lastClosureEmptiedSession`, `incompleteTopologyWithheld`, `allPlacementsConfirmed`, `survivingFramesRestored`, `nativeSourcesRemoved`, `managementRevoked`, `noFailures`) with `tabSupport: "verifiedInOwnedSession"` and `cleanup: "closed"`.
  - Finder native-tab membership & singleton detection (`ruby scripts/check-finder-documents.rb --new-tab captures/finder-tabs-increment59`) passes all 7 checks (`twoCreatedIDs`, `ownedWindowsObserved`, `ownedWindowsEligible`, `shallowAssociationsObserved`, `ownedSingletonsConfirmed`, `nativeSourcesRemoved`, `sharedMembershipVerified: true`) and cleans up all 3 created IDs.
  - All 120 Swift regressions pass in debug and release (32 core, 88 platform), including stacked-column native-tab reconciliation (`NativeTabTopologyTests`) and multi-display/multi-Space coordination (`DisplaySpaceCoordinatorTests`). `paperi probe-preview-input` passes all 11 checks.
- Increment 58: `PaperiSpaceProbe --backend mission-control` passes outbound (`1`→`378`) and return (`378`→`1`) membership and active-Space follow in both debug and release (`captures/space-probe-mission-control-debug.json`, `captures/space-probe-mission-control-release.json`). `--backend drag-switch` reports `unsupported` (exit 2) because symbolic hotkeys `79`/`81` are disabled on this host (`captures/space-probe-drag-switch-final.json`).
- Increment 57: debug Terminal resize run passes eight baseline/membership/geometry/column-restoration checks (`captures/terminal-resize-increment57-final/summary.json`).
- The last full ten-mode integrated cycle passed 9/10 and has not been repeated. Intermittent AX role/reference and restart rediscovery failures remain open.

### Next

Wire `DisplaySpaceCoordinator` and the Mission Control Space transfer backend into an opt-in live session preview across Spaces, validate Preview compatibility, and run live stacked-column native-tab probes. Physical/global keyboard routing stays deprioritized; abrupt-exit recovery, OS/cross-display popup recovery, physical multi-monitor validation and baseline/soak measurements remain release gates.

## Handoff — 2026-11-09

Implementation through increment 59 validates:
- Sustained shared-session native-tab lifecycle on owned Terminal windows (`paperi probe-terminal-session`, 12/12 checks).
- Finder native-tab membership learning alongside tab-bar-free singleton detection (`check-finder-documents.rb --new-tab`, 7/7 checks).
- Stacked-column native-tab reconciliation (`ScopedLayoutSession.reconcileTabs`, `slurpFocused`, `barfFocused`) and multi-display/multi-Space container coordination (`DisplaySpaceCoordinator`).
- Mission Control cross-Space window transfer round trip (`PaperiSpaceProbe --backend mission-control`) in debug and release.

### Resume here

1. Connect `DisplaySpaceCoordinator` (`Sources/PaperiPlatform/DisplaySpaceCoordinator.swift`) to a live multi-Space preview/probe that combines `ScopedLayoutSession` with the Mission Control Space transfer sequence from `Tools/SpaceProbe/main.m`, verifying that moving a single-window or multi-tab logical slot across user Spaces updates both source and destination sessions and confirms final AX placements.
2. Exercise stacked-column native-tab reconciliation in a live AppKit fixture probe (combining `slurp`/`barf` with native tab switch/detach/merge/close).
3. Validate Preview.app native-tab compatibility using the shared `nativeTabEvidence` and `singletonCandidates` path.

### Code and validation entry points

| Purpose | Entry point |
| --- | --- |
| Shared session, stacked-column reconciliation, slurp/barf and stop guards | [ScopedLayoutSession.swift](../Sources/PaperiPlatform/ScopedLayoutSession.swift), [ScopedLayoutSessionTests.swift](../Tests/PaperiPlatformTests/ScopedLayoutSessionTests.swift), [NativeTabTopologyTests.swift](../Tests/PaperiPlatformTests/NativeTabTopologyTests.swift) |
| Multi-display and multi-Space session coordinator | [DisplaySpaceCoordinator.swift](../Sources/PaperiPlatform/DisplaySpaceCoordinator.swift), [DisplaySpaceCoordinatorTests.swift](../Tests/PaperiPlatformTests/DisplaySpaceCoordinatorTests.swift) |
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
