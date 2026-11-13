# Review plan — 2026-11-13

A review of the project at `02ad634`, covering three goals: maintainability, swipe
smoothness, and behaviour design. The original recommendations are preserved below; see the progress update for current implementation status. Items marked
**(verify)** are hypotheses from reading the code that need a measurement before
acting on them.

## Progress update — 2026-11-13

The working tree contains a first implementation pass. Verification now uses
`./scripts/swift.sh test`: the wrapper explicitly loads the bundled TestingMacros
plugin, avoiding the missing-plugin errors from a direct toolchain invocation.
The obsolete speed-cap and Bézier tests have been replaced with spring velocity,
settling, reversal, overshoot, and directional-gain regressions.

- M1 partial: commands, focus animation and swipe code are separate extensions.
  This improves navigation but does not yet provide an isolated `SwipeController`
  or its fake dependencies.
- S1–S4 initial implementation: directional travel, predicted tracking, spring
  landing and projected release are present. Rigid strip rendering and complete
  velocity continuity still need review; tracking retains a visual velocity filter.
- P3 and P4 implemented in the working tree: symbol caching and named event types.
- P2 initial fail-safe implemented: independent AppKit/device finger counts are
  compared on nonempty touch frames. Four disagreements spanning at least 150 ms
  disable the blocking tap until restart; the reason appears in
  `status.gesture.appGestureBlocking`. This still needs live hardware validation;
  menu reporting and private-source health diagnostics remain open.
- B1 and live performance verification remain open.

Validation: 105 core and 171 platform tests passed with the default build system.
The native SwiftPM build system cannot find this host’s bundled Testing module.

Next: record first-frame latency and tracking error before tuning further;
review spring launch velocity and catch transitions with real gestures. Keep
MultitouchSupport fail-safe validation ahead of optional behaviour expansions.
Do not remove compatibility settings or private API fallbacks without evidence.
Automated tests do not establish perceived smoothness or system gesture safety.

## Summary: what I would do first

| # | Change | Goal | Effort | Why first |
| --- | --- | --- | --- | --- |
| 1 | Track fingers at constant gain in points, not "one slot per `columnTravel`" (S1) | Smoothness | M | Largest single difference from the native Space swipe |
| 2 | Remove the tracking speed cap, replace the low-pass with prediction (S2) | Smoothness | S | Fast flicks visibly trail the fingers today |
| 3 | Spring landing driven by finger velocity, one projected-position commit rule (S3, S4) | Smoothness | M | Removes the lurch at release; deletes four tuning heuristics |
| 4 | Stop dropping gestures during landing, hand-off and fade (B1) | Behaviour | S–M | Silent drops read as unreliability |
| 5 | Extract `SwipeController` from `LiveManager` (M1) | Maintainability | M | 1,370 of 2,858 lines; unblocks 1–4 being testable |
| 6 | Self-check the MultitouchSupport layout; cache `dlsym` lookups (P2, P3) | Private APIs | S | Turns "two-finger scrolling stops" into a safe failure |

Suggested order: M1 (pure move, no behaviour change) → S2 → S1 → S3/S4 → B1 →
the rest as wanted. S1–S4 all touch the same 300 lines, so doing M1 first keeps
the diffs readable.

---

## 1. Maintainability

### M1. Split `LiveManager.swift` (2,858 lines, one class)

`LiveManager` holds reconciliation, the keyboard focus animator, the whole
swipe feature, window actions, the journal, command dispatch and status. The
`swipe` section alone is `LiveManager.swift:1049–2414`. Proposed split, in
order of payoff:

| New type | Lines today | Contents |
| --- | --- | --- |
| `SwipeController` | 1049–2414 | `Swipe`, `Landing`, touch handling, `beginSwipe`/`endSwipe`/`land`/`catchLanding`, standalone hints, simulation |
| `WindowActions` (static, no manager state) | 1878–1928, 1978–1985, 2106–2147, 1449–1508 | close button / ⌘W, minimize, New Window menu lookup, keystroke posting, open app |
| `FocusAnimator` | 845–1047 | `motion*` state, `animateFocus`, `confirmFocus`, performance counters |
| `RestoreJournal` | 226–260, 2507–2524 | persisted journal; see M3 |
| `LiveManager+Commands` | 2532–2858 | `handle`, `status`, `checkApps`, tray callbacks |

`SwipeController` needs only a narrow view of the manager: the session and
surveys for a Space, `apply`, `raise`, `reveal`, `scheduleRefresh`, and the
config. Define that as a small protocol so the controller can be driven in
tests with a fake strip and a fake overlay (today nothing in the swipe path
above the pure `SlotSwipe` reducer is tested).

### M2. Replace the `Swipe` flag bag with a mode enum

`Swipe` (`LiveManager.swift:1054`) has `closing`, `pulling`, `turned`,
`pullAction`, `tabClose`, `caught`, `ready`, `tracking`, `failed`, `released`
plus five computed properties (`showsTabClose`, `tabCloseMode`,
`showsNewWindow`, `showsIndicator`, `indicatorStyle`) that decode them. Many
combinations are meaningless (`turned` without `pulling`), and "what does a
release do" is decided in three places that must agree:

- `finishClose` dispatch (`:1937–1940`)
- the capture-failed fallback chain in `endSwipe` (`:2228–2242`)
- `performStandalonePull` (`:1449`) and `updateStandaloneHint` (`:1250`), a
  parallel implementation for "no strip under the pointer"

Proposal: `enum Mode { case strip, close(CloseKind), action(GestureAction, turn: Direction?) }`
and one `func perform(_ action: GestureAction, on target: Target?)` used by the
overlay path, the failed-capture path and the standalone path. The standalone
case becomes "a swipe whose target has no snapshot", not a second state machine
(`standalonePull`, `standaloneAction`, `standaloneOverlay`,
`standaloneHintDirection`).

Likewise `SlotSwipe.State` has four cases with the identical payload
(`active`/`closing`/`pulling`/`turning`, `SlotSwipe.swift:24–27`) and
`SlotSwipe.Action` has four `…Started`/`…Updated` pairs. One
`tracking(Axis, Track)` case removes the four near-identical arms in `move`,
the duplicated velocity filter (`:236–239` vs `:277–279`) and the duplicated
release rule (`releases` `:327` vs `horizontalDecision` `:396`, which repeat
the same stale-velocity and flick tests).

### M3. Concrete duplications

| What | Where | Fix |
| --- | --- | --- |
| "Frontmost app's focused window ID" | `LiveManager.swift:637, 884, 1454, 1910, 2550, 2759` | one `AX.focusedWindow(pid:timeout:)` |
| `layout.columns[loc.column].slots[loc.row].activeMember` | 7 sites (`:786, 1208, 1649, 1658, 2542, 2594, 2696`) | `Layout.focusedWindow` / `Layout.window(in:)` in Core (a private copy exists at `:1656`) |
| Hand-off settle loop | `finishHandoff` `:2082` and inline in `land` `:2349–2374` | `land` calls `finishHandoff` |
| Close and minimize exits | `finishClose` `:1941–1949` vs `finishMinimize` `:1993–2000` (same slide + fade + poll) | one `flyOut(direction:then:)` |
| `cancelMotion(); motionFrames.removeAll()` | 13 sites | fold the clear into `cancelMotion(resetFrames:)` |
| `firstWriteMS = nil; finalWriteMS = nil; confirmedMS = nil` | 4 sites | `FocusAnimator.beginTiming()` |
| Window-level map from `CGWindowListCopyWindowInfo(.optionAll)` | `:495, 909, 2732, 2790` | one `WindowServer.snapshot()` returning levels, frames, z-order |
| AX→AppKit y flip via `NSScreen.screens.first?.frame.height` | 6 files | one `ScreenGeometry` helper |
| Warning popovers | `LiveApp.swift:197–228` vs `:251–280` (identical but for title and button) | `showPopover(title:body:action:)` |
| Gesture-conflict polling | `LiveManager.checkGestureSettings` `:1237` and `LiveApp.checkGestureSettings` `:238` | manager publishes conflicts; app only renders |
| stderr logging | 22 `FileHandle.standardError.write(Data(...))` sites, three log prefixes | one `Log.verbose(_:)` |
| Two restore journals | `FrameRestorationJournal` (probes only) vs the tuple dict + `persistJournal` in `LiveManager` | live mode uses the tested type; add persistence to it |
| Probe helpers | `space`/`valid`/`classification`/`matches`/`write` closures re-declared in `NativeTabProbe`, `TerminalPlacementProbe`, `LifecycleProbe`, `PlacementProbe` | shared `ProbeSupport`; or see M5 |
| Overlay window construction | `SnapshotTransition.prepare` `:93–106` vs `prepareStandaloneIndicator` `:133–146` | one factory |

### M4. Dead or misleading code

- `LiveManager.swift:287–289`: empty `if` holding only a comment.
- `SlotSwipe.advanceVisualProgress` is public but only called by
  `followVisualProgress`; both go away with S2.
- `Paging` (`Layout.swift:328–359`) is used only by its own test; superseded by
  `SlotSwipe`. Remove, or revive it for B2.
- `LiveConfig.edgeHint` / `edgeHintColor`: "no longer displayed", but still
  validated and tested. Accept and ignore the key instead.
- `handle` matches `"stop"` twice (`:2655` and `:2679`).
- `main.swift --menu` still shows "Feasibility build — management inactive".
- `docs/SNAPSHOT-EXPERIMENT.md` documents `travel: 0.25` and one-slot rules
  that have since changed; `docs/STATUS.md` still lists finished swipe work as
  "next". Fold what is still true into `DEVELOPMENT.md`.
- The `paperi` usage text in `main.swift` omits `swipe`, `tray`, `focus up|down`.

### M5. Move probes and test aids out of the shipped binary

`NativeTabProbe`, `TerminalPlacementProbe`, `LifecycleProbe`, `PlacementProbe`,
`SpaceTransfer` (scripts the Dock's Mission Control AX tree),
`PreviewCommandInbox`, and the recorder CLI total roughly 2,000 lines and 14
`main.swift` subcommands. They are regression tools, not product. Move them to
a `PaperiProbes` target with its own `paperi-dev` executable. The release app
then contains only `run`, `msg`, `check-apps`, `login`, `restore`, which also
shrinks the private-API call sites that ship (section 2).

### M6. Typed command replies and timing

- Commands return `[String: Any]` and callers branch on `res["ok"] as? Bool`
  (`:1341, 1353`) or compare error strings (`fullScreenRefusal`, `:1310`). Give
  `beginSwipe` a `Result<Void, SwipeRefusal>`; build the JSON dictionary only
  at the IPC boundary.
- `ProcessInfo.processInfo.systemUptime` appears 123 times, mixed with
  `CACurrentMediaTime()` and `NSEvent.timestamp`. They share a timebase, but a
  single `Clock.now` makes the swipe controller testable with a fake clock.
- 29 `Timer` / `asyncAfter` / `Task.sleep` waits in `LiveManager`, mostly fixed
  delays (`[0.35, 0.8, 1.5]`, 25 ms polls). Where an AX notification exists
  (destroyed, miniaturized, moved), await it with a timeout instead of polling.

---

## 2. Private APIs

Current surface, all behind `PaperiBridge.c`:

| Interface | Needed? | Recommendation |
| --- | --- | --- |
| `_AXUIElementGetWindow` | Yes. No public AX→window-ID mapping; frame/title matching would be worse | Keep |
| `SLSMainConnectionID`, `SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows` | Yes. No public per-window or per-display Space query | Keep |
| `SLSSpaceGetType` | Probably not **(verify)** | P1 |
| `SLSGetActiveSpace` | Only a fallback | P1 |
| MultitouchSupport (`MTDeviceCreateList`, `MTRegisterContactFrameCallback`, `MTDeviceStart/Stop`, 96-byte contact layout) | Yes for app-gesture blocking; the documented alternative (touches via `NSEvent` in the active tap) was measured and rejected | Keep, harden (P2) |
| Raw `CGEventType` 18/19/20/29/30/31/32 in tap masks | Values are the public `NSEvent.EventType` raw values; using them as tap mask bits is undocumented but has no alternative | P4 |

- **P1. Drop two SkyLight calls.** `liveTopologies`
  (`DisplaySpaceCoordinator.swift:107–118`) already reads `"Current Space"`
  from `SLSCopyManagedDisplaySpaces` and uses `SLSGetActiveSpace` only if that
  key is missing. Each Space dictionary in the same payload carries a `type`
  field **(verify on 26.7.2)**; if so, `paperi_space_type` and
  `paperi_active_space` can both go, leaving three SkyLight symbols.
  `SkyLightHealth` should then validate that key instead.
- **P2. Make a changed MultitouchSupport layout fail safe.** Today a changed
  record layout gives wrong finger counts, and the documented worst case is
  that two-finger scrolling stops system-wide. The listen-only tap already has
  an independent count from `NSEvent.allTouches()`. Compare the two for the
  first frames of each sequence; after N disagreements, stop the blocker, and
  report it in `status.gesture` and the menu. Also add MultitouchSupport to the
  health report, which covers only SkyLight today.
- **P3. Resolve symbols once.** Every `paperi_window_id` call runs
  `dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow")`, and each SkyLight wrapper
  runs its own `dlsym` per call (`PaperiBridge.c:19–52`). These are called per
  window per refresh and in swipe paths. Resolve all pointers inside the
  existing `pthread_once`.
- **P4. Name the event types.** `29` is a bare literal in `TouchSource.swift:74, 87`
  and again in `AppGestureBlocker.swift:151–159`. Define them once from
  `NSEvent.EventType.gesture.rawValue` etc., with the one "undocumented as
  CGEventType" comment in one place.
- **P5. Keep private calls out of feature code.** `paperi_*` is called from 11
  Swift files, mostly probes. After M5, wrap the remainder in one Swift
  `WindowServerQueries` type so product code has a single private-API seam,
  mockable in tests.
- **Do not add** `CGSHWCaptureWindowList` or similar private capture calls for
  speed (see S5); ScreenCaptureKit with caching should be enough.

---

## 3. Swipe smoothness

What the native four-finger Space swipe does that Paperi does not:
content moves a fixed distance per unit of finger travel; it has no added lag
and no speed limit; release hands the finger's velocity to a spring; and the
commit decision is "where would this coast to". The items below are ordered by
expected effect.

### S1. Constant gain: track in points, not in slots

Today one full `columnTravel` (30% of the trackpad) always equals progress 1,
and progress 1 is "however far the strip must scroll to reveal the next
column" (`swipeDestinations`, `:1627`). That distance might be 300 pt for a
narrow column and 1,400 pt for a wide one, so the same finger movement moves
content at very different speeds from one swipe to the next. The hand cannot
learn it, which is most of what "not natural" means here.

Proposal: the reducer accumulates finger travel in a fixed unit and the
controller converts it to strip offset in points with one constant
(for example, full trackpad width = `gain × canvas.width`, `gain` ≈ 1.2,
replacing `columnTravel`). Progress becomes derived:
`progress = offsetPoints / slotDistancePoints`. Narrow columns then commit
with a short swipe and wide ones need a longer one, which is what direct
manipulation feels like. `shown(raw, origin:)` (the lead-in remap,
`SlotSwipe.swift:311`) stays, but applied in points.

A related non-rigidity: `LiveReconciliation.interpolate` (`:132`) makes tucked
windows wait and then move for only "their share" of the gesture. That is
correct for the real windows' end positions, but in the overlay nothing forces
it: images could sit at their *virtual* strip positions (`Placement.virtualX`)
and translate rigidly, clipped by the overlay's bounds, and only the real
windows get tucked. Then the whole strip is one rigid body, and one container
layer with a single transform replaces N per-layer position writes per frame
and N keyframe animations per landing.

### S2. No speed cap, prediction instead of low-pass

`advanceSwipeVisuals` (`:1786`) follows the finger through
`followVisualProgress`: an exponential filter (16 ms time constant) plus a hard
cap of `maximumVisualSpeed = 8` slots/s.

- A quick flick covers 0.3 trackpad widths in 50–80 ms, i.e. 12–20 slots/s.
  The cap makes the images trail and the release then happens with the images
  well short of the finger. Remove the cap while tracking. Its original
  purpose (no jump when the capture lands late) is better served by a one-off
  short ease from the capture frame to the finger position.
- The filter adds lag in order to hide beating between touch reports and
  display refresh. The lower-latency fix is extrapolation: keep the last
  sample's time and filtered velocity, and each display tick place the strip
  at `position + velocity × (link.targetTimestamp − sampleTime)`, clamped to
  about one frame of lead. That removes both the beat and the lag.

### S3. Spring landing from finger velocity

- The landing is a cubic Bézier whose initial slope approximates the release
  speed (`settleCurve`, `:145`), with duration from two heuristics
  (`settleDuration` ×2). A critically damped spring
  (`x(t) = target − (d + (v₀ + ωd)·t)·e^(−ωt)`) gives exact velocity
  continuity for any release speed with one parameter. Sample it into the
  existing keyframe animation (it must stay a Core Animation animation so the
  synchronous AX writes at release cannot stall it, `:2309`).
- It also simplifies catching: `Landing.progress(at:)` becomes the closed form
  instead of a 40-step bisection of the Bézier (`settleFraction`, `:417`).
- Launch velocity comes from `state.visualVelocity`, a 30 ms filter over the
  already smoothed and capped on-screen progress, so landings start slower
  than the fingers were moving. Use the reducer's finger velocity (after S2
  the two agree anyway).
- Use the same spring for snap-back, close fly-out and minimize.

### S4. One commit rule: projected resting position

Release is decided by three interacting rules: threshold (0.5), flick
(≥ 1.5 slots/s with ≥ 0.12 travel), and "retreating" veto. Replace with
`projected = position + velocity × τ` (τ ≈ 0.15–0.2 s, i.e. where the spring
would carry it) and commit to the column nearest `projected`. It behaves like
the three rules in the common cases, has no discontinuity between "just under
flick speed" and "just over", and extends naturally to multi-column flicks
(B2). `commitThreshold` and `flickVelocity` collapse into one optional
"sensitivity" setting. Stale-velocity decay (`:330`) stays.

### S5. Time to first frame

The overlay cannot show until the capture finishes, so a fast swipe's early
motion is invisible. `swipeMetrics.captureMS` already records this; start by
logging its distribution over a day of use.

- `SCShareableContent.excludingDesktopWindows` is fetched on every swipe
  (`SnapshotTransition.swift:32`) and again in `capture(more:)` and the tray.
  Cache it and invalidate on window create/destroy/Space change, which the
  manager already observes.
- Off-screen neighbours rarely change. Capture them when idle (after a landing
  `captureReachable` already does this for the next swipe; extend it to after
  any refresh that changes the layout), so that finger-down captures only the
  background and the visible windows.
- `beginSwipe` runs on every three-finger touch-down, before any movement, and
  synchronously does two `CFPreferencesAppSynchronize` calls
  (`GestureConflict.checkLive`), a full `CGWindowListCopyWindowInfo(.optionAll)`,
  one SkyLight query per strip window, and two layout solves. The conflict
  check is already polled once a second; use that cached result. Add a
  `beginMS` metric.

### S6. Visible seams at overlay show and hide

- Shadows are re-drawn approximations (`addShadow`, `:168`: 0.4/16 pt active,
  0.22/7 pt inactive), so the shadow changes shape the moment the overlay
  appears and again when it fades. Capture with shadows
  (`ignoreShadowsSingleWindow = false`) and place the layer using the
  capture's own content rect rather than the window frame **(verify that the
  filter reports the shadow margins)**.
- After a commit the newly focused window is live-drawn as active while its
  snapshot was inactive, and the 180 ms cross-fade (`fadeOut`, `:444`) shows
  the change as a soft pop. Shorten to ~80 ms, or cross-fade only that one
  layer.
- End of landing currently waits: settle polls at 25 ms intervals (two equal
  reads needed, so ≥ 25–50 ms), plus a fixed 34 ms, plus the fade. Poll per
  display frame instead of every 25 ms, and skip the fixed hold when
  `maxDeviation` was 0.

### S7. Frame pacing **(verify)**

`FrameClock` uses `screen.displayLink` without a
`preferredFrameRateRange`. On ProMotion displays, confirm with the existing
`trackingFrames` / `trackingMaxFrameMS` metrics that ticks arrive at 120 Hz
during tracking; if not, request `CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)`.
The swipe guard timer (120 Hz `Timer`, `:1569`) checks mouse buttons, AX trust
and display arrangement 120 times a second; fold it into the display-link tick
or drop it to 10 Hz.

### S8. Keyboard focus scroll

Separate renderer, and the roughest motion in the app: a 60 Hz `Timer` (not
display-synced) writing AX positions per window per tick, eased with
smoothstep (`:966–976`).

- Smoothstep starts from zero speed, so each key press has a soft start that
  reads as input lag. Use the S3 spring (fast start, soft stop).
- A repeat press restarts from rest at the current frames; carry the velocity
  into the retarget so held keys glide instead of pulsing.
- Drive it from a display link.
- Longer term, once S5 makes captures warm, the snapshot renderer could serve
  keyboard focus too and the AX-write animator could be deleted. That is an
  experiment, since it adds a Screen Recording dependency to keyboard use.

---

## 4. Behaviour design

### Places I find unintuitive

- **B1. Gestures are silently dropped while an animation finishes.**
  `gestureBlockedByAnimation` (`:1161`) rejects a whole touch sequence that
  begins during a keyboard focus scroll, a close/minimize exit, or (for
  anything but a horizontal swipe) a landing, hand-off or fade. In practice:
  swipe right, then immediately swipe up to close what you landed on, and
  nothing happens. Accept the sequence and defer its capture until the
  hand-off completes, or finish the hand-off early.
- **B3. Swipe and keyboard disagree about "next".** ⌥⌘K focuses the adjacent
  column. A swipe goes to "the nearest column that needs scrolling"
  (`swipeDestinations`), which skips columns that are already visible. With
  two half-width columns on screen, the same intent lands on different
  windows, and a visible unfocused column cannot be focused by swiping at all.
  Pick one rule. With S1 the natural one is: the swipe scrolls the viewport,
  and focus goes to the column nearest the pointer (or centre) when it rests.
- **B4. No default key to focus within a stack.** The defaults bind J/K to
  focus left/right and the arrows to *swap*. `focus up|down` exists as a
  command but has no binding, so a stacked window can only be focused by
  clicking. Also J/K meaning left/right while H/L resize will surprise anyone
  with vim habits (H/L left/right, J/K down/up). I would default to
  H/J/K/L = focus, and move width to `-`/`=` or `[`/`]`.
- **B5. The whole app pauses when displays are side by side.** That is the
  most common multi-display arrangement. The constraint is that a column
  parked past a shared edge lands on the other display. Worth an experiment:
  on a shared edge only, park columns past the *bottom* edge (1 pt showing)
  rather than the side; macOS keeps a window on the display holding most of
  it, so it stays put. That side loses its peek sliver, but the app works.
- **B6. Out of the box, the gesture is off.** Three fingers is the default,
  and macOS commonly ships with three-finger Mission Control / full-screen
  swipes, so a new user's first experience is a warning popover. Add
  `"fingers": "auto"`: use whichever of 3 or 4 the system is not using.
- **B7. L-shaped gestures.** "Down, then right" (close tab) and "down, then
  left" (minimize) are hard to discover, slow to perform, and their meaning is
  arbitrary. Meanwhile swipe up already closes a tab when it knows the window
  has tabs. Two changes would help: make *up* the single "close" gesture by
  letting `tabCloseApps` be learned (offer to add an app the first time ⌘W
  fallback is used), and make down-left/right optional rather than default.
- **B8. Hidden and minimized windows lose their place.** They leave the strip
  and return "beside the focused column". ⌘H, then ⌘-Tab back, and the window
  is somewhere else. Remember the left neighbour at removal and reinsert
  there if it still exists.
- **B9. Dragging a stacked window's edge to change its height snaps back**
  (documented as "ignored; use `height +/-`"). Width drags are adopted; height
  drags should update the row weights the same way.
- **B10. Page dots.** They look interactive but ignore the mouse; a stack of
  two shows as two dots (so it reads as two columns); and nothing marks which
  dots are currently on screen. Group dots by column, draw a viewport outline
  around the visible range, and open the tray on hover or click.
- **B11. Config vocabulary.** `travel` vs `columnTravel`; `singleton` vs
  `tabCloseApps` (both mean "this app draws its own tabs"); one
  `swipeDownApp` shared by three gestures; manual "Reload Config". Suggested:
  per-app rules (`"apps": {"com.google.Chrome": {"tabs": "inContent"}}`)
  driving both tab handling and close behaviour, and auto-reload on file
  change with errors shown in the menu.

### Efficiency suggestions

- **B2. Free scrolling with snap instead of one slot per swipe.** With S1 and
  S4 in place, let the strip follow the fingers across any number of columns
  and settle on the column nearest the projected resting point. A hard flick
  then crosses several columns; a slow drag still moves one. This replaces the
  catch-a-landing machinery (`catchLanding`, `PathLeg`, `caught`/`origin`/
  `center`) with ordinary retargeting, and is how niri and PaperWM behave.
  Cost: images for columns further out must be captured lazily as they
  approach, within the existing 256 MB texture budget.
- **B12. Gestures and hotkeys share one command vocabulary.** Hotkeys already
  map key → `paperi msg` command. Do the same for gestures:
  `"gesture": {"actions": {"up": "close", "down": "new-window", "tap": "tray"}}`
  with `close`, `close-tab`, `minimize`, `new-window`, `open <bundle>` added as
  commands. Users can then bind any gesture to any command (up → `tray`,
  down → `center`), and `SwipeDownAction`, `TapAction` and their special cases
  in the controller disappear (ties into M2).
- **B13. Tray.**
  - Open it with the *focused* window's thumbnail under the pointer rather
    than centring the tray on the pointer. "One to the right" is then always
    the same hand movement.
  - Show it immediately with app icons and titles, and fill thumbnails in as
    captures arrive; today it stays hidden until the first capture finishes.
    At 116 pt, two terminal thumbnails are indistinguishable without a title.
  - Make ⌥⌘T usable from the keyboard: arrows or J/K to move, Return to
    focus, Esc to close, and type-to-filter by app or title.
  - Flick a thumbnail up to close that window, consistent with the main
    gesture.
- **B14. Width presets.** `width +/-` moves in 10% steps. Add `width cycle`
  through ⅓ / ½ / ⅔ of the canvas (PaperWM and niri both have this); one key
  gets the two layouts people actually use.
- **B15. Drag to reorder beyond adjacent columns.** Window drags only target
  the neighbouring columns and the strip does not scroll during a drag, while
  the tray can reorder anywhere. Auto-scroll the strip when the dragged window
  nears a canvas edge.
- **B16. Focus after close.** Default is `left`. When a column closes, the
  columns to its right slide in to fill the gap, so focusing `right` gives
  focus to the window that arrives under the pointer with no extra scroll, and
  matches browser-tab convention. I would default to `right`.
- **B17. A jump-back command.** `focus last` (toggle between the two most
  recently focused columns), bound to something like ⌥⌘Tab or a two-finger
  double-tap equivalent, covers the most common long-distance move in a long
  strip without the tray.

---

## Verification plan for the smoothness work

Before changing anything, record a baseline with the metrics that already
exist (`status.performance.swipe`): `captureMS`, `trackingFrames`,
`trackingDroppedFrames`, `trackingMaxFrameMS`, `releaseWritesMS`, `handoffMS`,
`landingCorrectionPT`, `totalMS`. Add:

- `beginMS` (touch-down to capture submitted),
- `firstFrameMS` (touch-down to overlay shown),
- per-tick finger-to-image error in points (the quantity S1/S2 reduce),
- release speed vs first landing-frame speed (the quantity S3 fixes).

A 240 fps phone recording of the trackpad and screen together is the practical
way to compare against the native Space swipe; do one before and one after
S1–S3.

## Slow tracking research and follow-up — 2026-11-13

Public sources reviewed do not establish the exact filter or transfer function
used for Mission Control / Spaces. Apple's
[trackpad event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)
distinguishes raw touches from driver-interpreted gestures; the two should not
be assumed to have identical motion quality.

[Chromium's scrolling investigation](https://blog.chromium.org/2023/08/smoothing-out-scrolling-experience-in.html)
identified inconsistent sampling and predictor output as causes of slow-scroll
jank, and reported improvement with the
[1€ adaptive filter](https://gery.casiez.net/1euro/). This supports trying
speed-adaptive temporal filtering; it does not establish that Apple uses it.

The follow-up implementation adds an adaptive display-target filter with an
8 Hz minimum cutoff, a cutoff increase of 40 per unit of filtered progress
speed, and a 10 Hz derivative cutoff. A 0.002-progress reversal tolerance
accumulates movement from the directional extremum, preventing a single tiny
opposite sample from retracting a predicted lead. Finger-to-distance gain is
unchanged. These values are initial tuning choices in slot progress units;
their perceived strength can vary with destination distance.

Regression checks cover stationary noise attenuation, genuine accumulated
reversal, forward monotonicity, convergence, and relative tracking lag at 60
and 120 Hz. The user verified the updated gesture tracking works in live use. Automated
validation passed 112 core and 171 platform tests, plus the executable build.
Detailed comparison against Spaces across column widths and capture catch-up
remains future measurement work. This follow-up includes the backward-motion
fix and adaptive smoothing after checkpoint `5177f9e`.

### Short, fast tracking excursions

A contained follow-up caps the adaptive tracking cutoff at 24 Hz. Previously,
a sudden report or rapid reversal could raise the cutoff enough to display
almost all its travel in one frame. The ceiling keeps a short smoothing
interval at high speed (about 6.6 ms steady-state lag); low-speed filtering,
gesture decisions and rendering architecture are unchanged. There is no
absolute movement-speed limit. Regression coverage replays short alternating
excursions at 60/120 Hz and checks that movement spans frames, remains bounded,
and follows promptly. This does not guarantee display cadence under main-thread
stalls; live feel still needs verification.

### Horizontal speed-based gain trial

At the user's request, live horizontal swipes now opt into a bounded acceleration
curve in `SlotSwipe`: 0.55× gain up to 0.05 trackpad widths/second, smoothly
rising to 1× at 1 width/second. Speed magnitude is filtered over 25 ms;
direction still comes directly from the finger delta. Gain multiplies deltas,
not total position, so changing speed cannot relocate the strip on its own.
Directional column travel still converts that displacement into progress.
Vertical gestures and their thresholds are unchanged. Core callers can retain
linear gain via the default configuration; live tracking explicitly enables
acceleration. These are trial tuning values, not a claim about Apple's private
Spaces implementation. Tests cover symmetry, bounded continuous gain, equivalent
steady motion at 60/120/240 Hz, increased reach at speed, and vertical behaviour.

Follow-up: while fingers remain down, the curve now tops out at normal (1×)
gain rather than adding a fast-motion distance boost. Additional flick reach
comes only from the existing velocity-based release decision, whose velocity
expires during a hold. A regression compares immediate release with a held
release after identical fast movement and confirms no travel is added at rest.
