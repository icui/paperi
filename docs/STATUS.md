# Implementation status

Current state and resume instructions only. The chronological increment log (increments 1–66) and the original initial-host validation are in [HISTORY.md](HISTORY.md); those entries describe evidence at their original dates.

## Current checkpoint: 2026-11-09 (increment 66)

Paperi now has a **live mode that manages real windows** of all regular applications (configurable via `config.json`) on the active Space of every display. While running it registers the Option–Command shortcuts copied from `~/.hammerspoon/init.lua` (J/K focus with Space fallback, arrows swap, F/C/S/L/H/U/N/I/O, 1–9 move to Space); each dispatches the same command as `paperi msg`.

```sh
./scripts/swift.sh build
.build/debug/paperi run -v                 # foreground, all regular apps; Ctrl-C stops and restores
.build/debug/paperi msg focus right        # same as ⌥⌘K
.build/debug/paperi msg status
.build/debug/paperi restore                # only after a crash: restores journaled frames
```

The responsible process (terminal/editor, or `dist/Paperi.app`) needs Accessibility access.

### Capability matrix

| Capability | Real apps (live mode) | Disposable fixture / tests | Remaining limits |
| --- | --- | --- | --- |
| Admission, closure, minimise/hide, eligibility | All regular apps: Terminal, Finder, Zed, Slack, Beeper, TextEdit verified | Verified | Excluded/`include`-limited apps untouched; unknown tab membership stays unmanaged |
| Popups (manage-all) | Control Center, Wi‑Fi menu, context menu, menu bar menu, Spotlight, Get Info, Open dialog, Save sheet: no managed window moved, management resumes after dismissal | Policy unit-tested | Windows without a fullscreen button float (override with `tile`); OS alerts from other processes and cross-display popups untested |
| Commands: focus, swap, width, height, center, split, slurp, barf, float | Verified via `paperi msg` | Verified | No scroll-only commands |
| Native tabs: active-first admission, merge (lazy), switch, detach, close active/last | TextEdit, Finder verified | Verified | Chromium/Electron in-content tab strips need `--singleton-app` |
| Space transfer (`space N`) with follow, tab containers | Verified Space 1 ↔ 378 (Mission Control) | Verified | Needs a unique window title; `expose-group-apps = 1` can cluster same-app untabbed windows |
| User Mission Control/display drags | Container follows to the new Space (observed after our transfers) | Unit-tested | Manual drag not separately exercised |
| Multi-display | Per-display strips, canvas updates, neighbour-aware parking of off-canvas columns | Unit-tested (negative origins, parking) | **No second physical display on this host**; cross-display `space N` is untested |
| Menu bar, pause/resume/reload, login item | Verified: menu Pause/Resume/Stop & Restore, reload applying gap and hotkey changes, custom ⌃⌥L binding, removed default, invalid entry reported; LaunchAgent written/removed | Hotkey parsing/merging unit-tested | Installed app not yet granted/launched; login start not exercised across a real logout |
| Stop/crash recovery | Stop restores admission frames, including after pause → manual move → resume → reload; journal persisted | Verified | Windows the app recreated after a crash are not matched |
| Global keyboard shortcuts (⌥⌘ defaults from the PaperWM config; `hotkeys` in config.json) | Verified via synthesized keys: J/K incl. edge → adjacent Space, H, →, I, O, C | Binding table unit-tested | 1–9 share the verified `space N` path but were not pressed live; conflicting registrations (Hammerspoon) are reported, not overridden; PaperWM's auto-center on create/destroy is not copied |
| Baseline, performance, soak | Not started | — | Release gates; refresh cost is reported as `lastRefreshMS` (58–99 ms with 6 windows, all apps; only apps with on-screen windows are surveyed) |

### Next

1. **Multi-display validation** on hardware with "Displays have separate Spaces" enabled: per-display strips, parking at a shared edge, cross-display `space N`, display unplug/replug.
2. **Daily use**: `./scripts/install.sh`, grant the installed app, enable Start at Login, run all day and record per-app limitations.
3. Decide whether to copy the Hammerspoon create/destroy auto-centering (`PaperWM.windows.centerWindow()`), which the plan flags as a pain point to guard.
4. Then baseline/performance (AX traffic per refresh, observer-driven incremental surveys), launch at login, and the eight-hour soak.

## Handoff — 2026-11-09

### Resume here

- Live mode entry points: [LiveManager.swift](../Sources/PaperiPlatform/LiveManager.swift) (refresh pipeline: displays → destruction → survey → ineligible removal → Space follow → per-app tab topology/admission → focus/reveal → width adoption → effects), [LiveCommandServer.swift](../Sources/PaperiPlatform/LiveCommandServer.swift), [LiveReconciliation.swift](../Sources/PaperiPlatform/LiveReconciliation.swift), shortcuts in [HotKeys.swift](../Sources/PaperiPlatform/HotKeys.swift), CLI in [main.swift](../Sources/Paperi/main.swift).
- A refresh runs on AX/workspace events (40 ms debounce) and every second. Only active Spaces are written; windows on inactive Spaces keep their session state until that Space is shown.
- Closure is recognised from `AXUIElementDestroyed`, window-server absence or owner exit; enumeration absence alone is never closure (inactive native tabs are not enumerated).
- Each app's tab reconciliation passes other apps' containers as identity partitions so one strip can mix apps.
- Disposable probes (`probe-*`, `preview-fixture`) remain as regression tools; prefer extending live mode over adding new probes.

### Code and validation entry points

| Purpose | Entry point |
| --- | --- |
| Shared session, stacked-column reconciliation, slurp/barf, Space reassignment and stop guards | [ScopedLayoutSession.swift](../Sources/PaperiPlatform/ScopedLayoutSession.swift), [ScopedLayoutSessionTests.swift](../Tests/PaperiPlatformTests/ScopedLayoutSessionTests.swift), [NativeTabTopologyTests.swift](../Tests/PaperiPlatformTests/NativeTabTopologyTests.swift) |
| Multi-display and multi-Space session coordinator & live Space transfer | [DisplaySpaceCoordinator.swift](../Sources/PaperiPlatform/DisplaySpaceCoordinator.swift), [SpaceTransfer.swift](../Sources/PaperiPlatform/SpaceTransfer.swift), [DisplaySpaceCoordinatorTests.swift](../Tests/PaperiPlatformTests/DisplaySpaceCoordinatorTests.swift) |
| External membership learning (`requireComplete: true/false`), lazy control resolution (`-25200`), singleton inspection and topology reconciliation (`allowLazyUnvisited: true/false`) | [NativeTabMembership.swift](../Sources/PaperiPlatform/NativeTabMembership.swift), [NativeTabTopology.swift](../Sources/PaperiPlatform/NativeTabTopology.swift), [SelectionAssociations.swift](../Sources/PaperiPlatform/SelectionAssociations.swift), [NativeTabMembershipTests.swift](../Tests/PaperiPlatformTests/NativeTabMembershipTests.swift) |
| Interactive preview & automated preview verification (`paperi preview-fixture`, `paperi probe-preview-input`) | [LifecycleProbe.swift](../Sources/PaperiPlatform/LifecycleProbe.swift), [PreviewCommandInbox.swift](../Sources/PaperiPlatform/PreviewCommandInbox.swift), [Tools/AXFixture/main.swift](../Tools/AXFixture/main.swift) |
| Working sustained AppKit native-tab fixture | [NativeTabProbe.swift](../Sources/PaperiPlatform/NativeTabProbe.swift), [check-native-tabs.rb](../scripts/check-native-tabs.rb) |
| Terminal sustained session, placement and resize probes | [TerminalPlacementProbe.swift](../Sources/PaperiPlatform/TerminalPlacementProbe.swift), [check-terminal-tabs.rb](../scripts/check-terminal-tabs.rb) |
| Finder native-tab and singleton discovery harness | [check-finder-documents.rb](../scripts/check-finder-documents.rb) |
| Cross-Space transfer probe (`skylight`, `mission-control`, `drag-switch`) | [Tools/SpaceProbe/main.m](../Tools/SpaceProbe/main.m) |
| Commands, prerequisites and broader validation modes | [README](../README.md), [feasibility protocol](FEASIBILITY.md), [implementation plan](../plan.md) |

### Key technical notes and remaining limitations for handoff

- **Active-First vs. Strict Native-Tab Modes:**
  - Strict mode (`NativeTabMembership.inspect(_:requireComplete: true)`, `NativeTabTopology.inspect(_:allowLazyUnvisited: false)`) remains the default for callers that require every tab button to be clicked before admission/reconciliation.
  - Active-first / lazy mode (`requireComplete: false`, `allowActiveOnly: true`, `allowLazyUnvisited: true`) tiles tabbed windows immediately via their active tab, resolves the active tab button via `TabSelectionEvidence.lazySelectedControl` even when macOS 26.7.2 AppKit returns `AXError.failure (-25200)` on unvisited sibling `AXTabButton`s, swaps the active representative in place when a background tab is clicked, and infers already-managed windows when merged into a single incomplete tab group.
  - **Remaining edge case:** If multiple already-managed windows are simultaneously hidden and merged into **multiple** incomplete tab groups at the same instant without being clicked, `NativeTabTopology.inspect` withholds inference until a tab is clicked or detached to disambiguate which hidden window joined which group.
- **Mission Control Cross-Space Transfers (`SpaceTransfer.swift`):**
  - Direct SkyLight Space transfer (`SLSMoveWindowsToManagedSpace`) fails on macOS 26.7.2 on this host and `SLSSpaceAddWindowsAndRemoveFromSpaces` is absent.
  - `SpaceTransfer.moveWindowViaMissionControl` transfers windows and native tab groups reliably across user Spaces via the Dock Mission Control AX tree (`mc` / `mc.display` / `mc.windows` / `mc.spaces.list`), re-reading thumbnail centers mid-drag and waiting `0.6s` after `SLSGetActiveSpace` confirmation before destination-Space AX writes.
  - **Remaining limitation:** When `com.apple.dock` `expose-group-apps = 1` ("Group windows by application") is active on a crowded Space, Mission Control groups multiple *untabbed* windows of the same application into a cluster; native tab containers move as a single unit without issue.
- **Multi-Display & Separate Spaces:**
  - `DisplaySpaceCoordinator` models per-display canvases (including negative-origin secondary monitors), 1-based user-Space numbering across displays, and atomic cross-Space/cross-display container transfers (`transferContainer`). Physical multi-monitor hardware with "Displays have separate Spaces" enabled has not yet been tested live on this single-display host.
- **Broader Release Gates:**
  - Intermittent AX reference/role failures and restart rediscovery remain open (last full 10-mode integrated cycle passed 9/10).
  - Live mode registers the user's Option–Command shortcuts (`HotKeys.swift`). Abrupt-exit crash recovery, OS/Control Center popup recovery, baseline/performance benchmarks, and daily-use soak remain release gates.

Commit validated milestones autonomously per the [commit policy](../plan.md#commit-checkpoints). Keep raw captures/scratch out of commits and preserve unrelated changes. Historical increments in [HISTORY.md](HISTORY.md) describe evidence at their original dates; this handoff and the current checkpoint are the resume instructions.
