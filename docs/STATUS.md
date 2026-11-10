# Implementation status

Current state and resume instructions only. The chronological increment log (increments 1–66) and the original initial-host validation are in [HISTORY.md](HISTORY.md); those entries describe evidence at their original dates.

## Current checkpoint: 2026-11-09 (increment 66)

Paperi now has a **live mode that manages real windows** of all regular applications (configurable via `config.json`) on the active Space of every display. While running it registers the Option–Command shortcuts copied from `~/.hammerspoon/init.lua` (J/K focus with Space fallback, arrows swap, F/C/S/L/H/U/N/I/O); each dispatches the same command as `paperi msg`.

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
| Mouse-held interactions (resize, move, click) | While the left button is held, refreshes only observe (reconcile state, detect drags, update the swap highlight); no frame is written and the strip neither scrolls nor reflows until mouse up, which triggers one refresh. A resized window's new width is adopted then. Widths above the cap are written back to the cap | Width adoption verified earlier; mouse-up deferral not yet exercised live | Height changes from edge drags are ignored (use `height +/-`) |
| Columns past an edge | Only the column nearest the visible area keeps its edge sliver or peek; columns beyond it are pushed to the screen edge with 1 pt on screen (macOS keeps part of every window on screen; fully off-screen positions are clamped back to 40 pt). Otherwise their overlap showed whichever window was raised last, which clicks and app activation change | Unit-tested; verified live with VS Code activated over a Zed peek | — |
| Manual window moves (title-bar drag) | Drag-to-swap: the dragged window follows the pointer untouched and nothing reflows mid-drag. While the pointer is over a window in the left or right column or in the dragged window's own stack (a sliver column's area is widened to 24 px at the canvas edge) that window gets a click-through `swapHighlight` mask; releasing there swaps the two, releasing elsewhere cancels. Two single-window columns swap whole (widths travel, as with `swap left/right`); otherwise the windows exchange positions and sizes. The window then snaps into its slot. A window moved without a drag (e.g. by the app) is put back | Column swap, cancel and mask verified live; stacked-row targets and slot swaps unit-tested, not yet exercised live | Only adjacent columns; dropping cannot create or dissolve a stack (use slurp/barf); the strip does not scroll mid-drag |
| Moving windows between Spaces/displays (user Mission Control drags; no Paperi command — `space N` and ⌥⌘1–9 were removed) | Container follows to the new Space, same display or another; its logical width travels unchanged (capped per display when placed, restored on return). Verified with real Mission Control drags (`paperi mission-control-move WID SPACE`) between the built-in display and an external display on its left, both directions, plus Space 1 ↔ 378 | Unit-tested | The moved window is inserted beside the focused column; focus is whatever macOS gives it (focusing it after Mission Control closed was dropped on 2026-11-10: leaving Mission Control by clicking a window made it ambiguous) |
| Multi-display | Per-display strips. Displays must be stacked (above/below each other): a column past a side edge then never overlaps another display (the window server assigns a window to the display holding most of it — verified: 51% stays, 45% moves). While any two displays sit side by side, no layout pass runs and live mode pauses (at launch or on a display change) with a popover under the menu bar item and a menu entry to Displays settings; resuming is refused until they are stacked, then it resumes on its own (unless the user had paused it). A window that follows a Mission Control move to another display gets that landing frame (fitted to the display) as its restore frame | Arrangement detection and fitting unit-tested; pause, popover and auto-resume verified live by switching the arrangement for the session | Upper-display tiling and unplug/replug tested by the user; separate Spaces disabled is unsupported |
| Menu bar, pause/resume/reload, login item | Verified: menu Pause/Resume/Stop & Restore, reload applying gap and hotkey changes, custom ⌃⌥L binding, removed default, invalid entry reported; LaunchAgent written/removed | Hotkey parsing/merging unit-tested | Installed app not yet granted/launched; login start not exercised across a real logout |
| Stop/crash recovery | Stop restores admission frames, including after pause → manual move → resume → reload; journal persisted | Verified | Windows the app recreated after a crash are not matched |
| Global keyboard shortcuts (⌥⌘ defaults from the PaperWM config; `hotkeys` in config.json) | Verified via synthesized keys: J/K (Space switching removed 2026-11-10), H, →, I, O, C | Binding table unit-tested | Conflicting registrations (Hammerspoon) are reported, not overridden; PaperWM's auto-center on create/destroy is not copied |
| Baseline, performance, soak | Not started | — | Release gates; refresh cost is reported as `lastRefreshMS` (58–99 ms with 6 windows, all apps; only apps with on-screen windows are surveyed) |

### Next

Instrumentation (`status.performance`) and the interruptible focus-scroll animation landed in commits 936697a and 86008e5; live multi-app profiling of them is still pending.

1. **Finish and validate the screenshot handoff first.** Keep the current keyboard animation; reserve screenshots for swipes. Diagnose the reported end offset using intended, captured, image and observed real geometry; validate alignment at overlay removal and after the following refresh.
2. **Three-finger one-slot scrolling** — see [the plan](../PLAN.md#next-feature-realtime-three-finger-one-slot-scrolling--planned-2026-11-10). Difficulty remains **medium-high**. Next milestones: system-gesture detection/config/warnings; background touch-capture validation; pure reducer plus snapshot tracking/commit/snap-back; live interruption and performance validation. AX finger-tracking fallback is optional later work.

**Realtime swipe gesture — 2026-11-10:** Trackpad swipe gesture is implemented across all four planned layers.
- **Pure model (`SlotSwipe` in `PaperiCore`):** direction lock (abandoning vertical dominance), signed progress in -1...1, rubber-band resistance beyond limits and at strip ends, mid-gesture reversal crossing zero, smoothed release velocity, flick commit, and commit/snap-back decisions. Unit tested across 9 cases.
- **System conflict detection (`GestureConflict` in `PaperiPlatform`):** checks `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad` for conflicting horizontal/vertical swipes and three-finger drag. Unit tested over fixture dictionaries.
- **Touch capture (`EventTapTouchSource` in `PaperiPlatform`):** session event tap on gesture events (type 29) extracting `NSEvent.allTouches()`, tracking touch identities, normalized deltas, and finger lift/arrival.
- **Live integration (`LiveManager` & `LiveApp`):** pointer-display ownership resolves the active Space under the mouse; `config.json` `gesture` settings (`enabled`, `fingers`, `travel`, `commitThreshold`, `flickVelocity`, `invert`); `status.gesture` reports enabled/blockedBy; menu bar warning item and popover direct to Trackpad Settings (`x-apple.systempreferences:com.apple.Trackpad-Settings.extension`); periodic and reload re-checks enable/disable the touch tap automatically.
- Build succeeds and all 174 tests pass (123 platform, 51 core). Next: live physical trackpad testing and tuning.
- **App gesture blocking (`AppGestureBlocker` / `AppGestureFilter` in `PaperiPlatform`):** an active session tap on its own thread withholds scroll (including momentum), pinch, rotate, smart-zoom, page-swipe, begin/end-gesture and touch events from apps from the moment the swipe's fingers are down until every finger lifts. Events that began before then still get their end. Verified live on 2026-11-10 in ChatGPT Atlas and a Chromium browser with a tail-appended listen tap: no event reached apps while 3 fingers were down, and the blocker averaged 0.3 ms per event.
  - **Fragile, may break after a macOS update:** finger counts come from the private `MultitouchSupport.framework` (`paperi_mt_*` in `PaperiBridge.c`, assuming a 96-byte contact stride with state at offset 20). If the framework is missing nothing is blocked; if the layout changes the counts are wrong, so app gestures leak or two-finger scrolling stops. See the README warning. Re-verify after every OS update.
  - Rejected approach: reading touches with `NSEvent(cgEvent:).allTouches()` inside the active tap. It waited on the busy main thread, macOS measured the tap at about 4 s per event, timed it out, and let everything through.

3. Continue daily-use, installed-app/login, recovery, and eight-hour soak validation. Upper-display tiling and unplug/replug have been tested by the user; separate Spaces disabled now pauses management.
4. Decide separately whether to add guarded create/destroy auto-centering.

## Handoff — 2026-11-09

### Resume here

- Live mode entry points: [LiveManager.swift](../Sources/PaperiPlatform/LiveManager.swift) (refresh pipeline: displays → destruction → survey → ineligible removal → Space follow → per-app tab topology/admission → focus/reveal → width adoption → drag detection → effects; reveal, adoption and effects wait for mouse up), [LiveCommandServer.swift](../Sources/PaperiPlatform/LiveCommandServer.swift), [LiveReconciliation.swift](../Sources/PaperiPlatform/LiveReconciliation.swift), shortcuts in [HotKeys.swift](../Sources/PaperiPlatform/HotKeys.swift), CLI in [main.swift](../Sources/Paperi/main.swift).
- Activation without a click (notification, Dock, ⌘-Tab) of an app whose window is off-canvas: the app (seen with Zed) may not answer AX for a moment, so its survey times out and it is skipped for 5 s. Its managed windows are still placed through the cached AX reference (if the window server reports them on the Space; one failed write stops writes to that app for the pass), and if it reports no focused window its frontmost managed window (CG z-order) is treated as focused, revealed and raised (`AXRaise` + `AXMain`). Verified live by clicking a Zed notification.
- A refresh runs on AX/workspace events (40 ms debounce) and every second. Only active Spaces are written; windows on inactive Spaces keep their session state until that Space is shown.
- Closure is recognised from `AXUIElementDestroyed`, window-server absence or owner exit; enumeration absence alone is never closure (inactive native tabs are not enumerated).
- Each app's tab reconciliation passes other apps' containers as identity partitions so one strip can mix apps.
- Disposable probes (`probe-*`, `preview-fixture`) remain as regression tools; prefer extending live mode over adding new probes.

### Code and validation entry points

| Purpose | Entry point |
| --- | --- |
| Shared session, stacked-column reconciliation, slurp/barf, Space reassignment and stop guards | [ScopedLayoutSession.swift](../Sources/PaperiPlatform/ScopedLayoutSession.swift), [ScopedLayoutSessionTests.swift](../Tests/PaperiPlatformTests/ScopedLayoutSessionTests.swift), [NativeTabTopologyTests.swift](../Tests/PaperiPlatformTests/NativeTabTopologyTests.swift) |
| Multi-display and multi-Space session coordinator; Mission Control drag test aid | [DisplaySpaceCoordinator.swift](../Sources/PaperiPlatform/DisplaySpaceCoordinator.swift), [SpaceTransfer.swift](../Sources/PaperiPlatform/SpaceTransfer.swift), [DisplaySpaceCoordinatorTests.swift](../Tests/PaperiPlatformTests/DisplaySpaceCoordinatorTests.swift) |
| External membership learning (`requireComplete: true/false`), lazy control resolution (`-25200`), singleton inspection and topology reconciliation (`allowLazyUnvisited: true/false`) | [NativeTabMembership.swift](../Sources/PaperiPlatform/NativeTabMembership.swift), [NativeTabTopology.swift](../Sources/PaperiPlatform/NativeTabTopology.swift), [SelectionAssociations.swift](../Sources/PaperiPlatform/SelectionAssociations.swift), [NativeTabMembershipTests.swift](../Tests/PaperiPlatformTests/NativeTabMembershipTests.swift) |
| Interactive preview & automated preview verification (`paperi preview-fixture`, `paperi probe-preview-input`) | [LifecycleProbe.swift](../Sources/PaperiPlatform/LifecycleProbe.swift), [PreviewCommandInbox.swift](../Sources/PaperiPlatform/PreviewCommandInbox.swift), [Tools/AXFixture/main.swift](../Tools/AXFixture/main.swift) |
| Working sustained AppKit native-tab fixture | [NativeTabProbe.swift](../Sources/PaperiPlatform/NativeTabProbe.swift), [check-native-tabs.rb](../scripts/check-native-tabs.rb) |
| Terminal sustained session, placement and resize probes | [TerminalPlacementProbe.swift](../Sources/PaperiPlatform/TerminalPlacementProbe.swift), [check-terminal-tabs.rb](../scripts/check-terminal-tabs.rb) |
| Finder native-tab and singleton discovery harness | [check-finder-documents.rb](../scripts/check-finder-documents.rb) |
| Commands, prerequisites and broader validation modes | [README](../README.md), [feasibility protocol](FEASIBILITY.md), [implementation plan](../plan.md) |

### Key technical notes and remaining limitations for handoff

- **Active-First vs. Strict Native-Tab Modes:**
  - Strict mode (`NativeTabMembership.inspect(_:requireComplete: true)`, `NativeTabTopology.inspect(_:allowLazyUnvisited: false)`) remains the default for callers that require every tab button to be clicked before admission/reconciliation.
  - Active-first / lazy mode (`requireComplete: false`, `allowActiveOnly: true`, `allowLazyUnvisited: true`) tiles tabbed windows immediately via their active tab, resolves the active tab button via `TabSelectionEvidence.lazySelectedControl` even when macOS 26.7.2 AppKit returns `AXError.failure (-25200)` on unvisited sibling `AXTabButton`s, swaps the active representative in place when a background tab is clicked, and infers already-managed windows when merged into a single incomplete tab group.
  - **Remaining edge case:** If multiple already-managed windows are simultaneously hidden and merged into **multiple** incomplete tab groups at the same instant without being clicked, `NativeTabTopology.inspect` withholds inference until a tab is clicked or detached to disambiguate which hidden window joined which group.
- **Space transfers are user-driven (Mission Control):**
  - Paperi has no command that moves windows between Spaces (`space N` and ⌥⌘1–9 were removed on 2026-11-10). Direct SkyLight transfer (`SLSMoveWindowsToManagedSpace`) fails on macOS 26.7.2 and `SLSSpaceAddWindowsAndRemoveFromSpaces` is absent, so a command would have to script Mission Control; the user moves windows there instead and live mode follows (refresh step 4).
  - `SpaceTransfer.moveWindowViaMissionControl` remains only behind the `paperi mission-control-move` test aid (Dock Mission Control AX tree `mc` / `mc.display` / `mc.windows` / `mc.spaces.list`; uses the destination display's Spaces bar).
- **Multi-Display & Separate Spaces:**
  - `DisplaySpaceCoordinator` models per-display canvases (including negative-origin secondary monitors), and atomic cross-Space/cross-display container transfers (`transferContainer`). Verified live with an external display on the left of the built-in display.
- **Broader Release Gates:**
  - Intermittent AX reference/role failures and restart rediscovery remain open (last full 10-mode integrated cycle passed 9/10).
  - Live mode registers the user's Option–Command shortcuts (`HotKeys.swift`). Abrupt-exit crash recovery, OS/Control Center popup recovery, baseline/performance benchmarks, and daily-use soak remain release gates.

Commit validated milestones autonomously per the [commit policy](../plan.md#commit-checkpoints). Keep raw captures/scratch out of commits and preserve unrelated changes. Historical increments in [HISTORY.md](HISTORY.md) describe evidence at their original dates; this handoff and the current checkpoint are the resume instructions.

### Display-settings guard — 2026-11-10

Upper-display tiling and unplug/replug have been tested by the user. Separate Spaces disabled is unsupported: Paperi now checks NSScreen.screensHaveSeparateSpaces, blocks layout and Resume, and shows a pause warning directing the user to Desktop & Dock → Mission Control. The warning explains the logout/login requirement. Interactive warning validation remains pending.

Validation: all 151 Swift tests passed, including shared-Spaces rejection for single and stacked displays.

Keyboard boundary feedback now uses a position-only bounce of the real strip; the blue edge bar has been removed. Bounce geometry and return positions are unit-tested; physical keyboard animation still needs interactive verification.
