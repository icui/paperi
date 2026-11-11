# Paperi

> Archived 2026-11-11: the requested feature set is implemented. Retained for historical context; proposed work and release gates below describe the original planning checkpoint, not an active roadmap. See [current status](../STATUS.md) for verification limits.

Draft plan for a standalone macOS scrolling window manager that reproduces this user's PaperWM.spoon workflow with lower latency and resource use.

Implementation has started. See [current status](../STATUS.md), [development instructions](../../README.md), and [feasibility protocol](FEASIBILITY.md). Release gates below remain open until verified; an in-memory tab-slot model does not establish working native-tab discovery.

## Recommendation

Build a native Swift menu bar app using AppKit, Accessibility observers, and a small Objective-C/C adapter for private window/Spaces APIs. Keep the layout engine independent of macOS APIs. Start with keyboard-driven parity and immediate frame changes. Next, instrument the current path, add a minimal interruptible same-Space focus-scroll animation, and tune performance against that implementation.

Replicate the intended interaction model and shortcuts, with explicit fixes for existing pain points. The implementation is free to use different algorithms, state models, event handling, and macOS integration; this is not a line-by-line translation or a requirement to preserve bugs. Swift is the proposed app language, with C/Objective-C where useful; validate the hot path before deciding whether more native code is necessary.

Do not embed Hammerspoon or a Lua runtime in the first version. Use PaperWM.spoon as a workflow reference, Hammerspoon as a macOS integration reference, and yabai as a systems-design reference. A language rewrite alone does not guarantee faster window manipulation: cross-process Accessibility calls, target application responsiveness, and system Space animations remain constraints.

## Inspection and evidence

Reviewed on 2026-11-06:

- User configuration: `/Users/ccui/.hammerspoon/init.lua`.
- This repository's README was empty; no existing application or architecture was present.
- Installed PaperWM.spoon: `/Users/ccui/.hammerspoon/Spoons/PaperWM.spoon`, commit `f86f76bae635307d6cb12c8d66693acff57cf82a`, with a clean working tree. Read its configuration, actions, layout, events, window operations, Space transfer code, Mission Control helpers, and license.
- Upstream Hammerspoon window and Spaces implementations and license, linked below. These were inspected on the upstream default branch, not a pinned copy matching the installed Hammerspoon binary.
- Upstream yabai window eligibility/rules, window metadata and display lookup, event handling, display management, and MIT license. Default-branch inspection identifies useful patterns, not proof that yabai solves all reported problems.

This is source inspection, not profiling. No runtime speed, CPU, memory, installed macOS version, or multi-monitor behavior has been measured. Confirm the minimum macOS release and development signing setup during the first milestone; initially target the user's current OS and Apple Silicon machine if applicable.

## Behavior to preserve

All shortcuts below use **Option–Command**. Only the explicit user mappings are bound; PaperWM's suggested default key table is not automatically the user's effective configuration.

| Keys | Required behavior |
| --- | --- |
| J / K | Focus the adjacent left/right column using the custom row lookup; at the end of the strip, flash a gentle edge hint instead (no Space switching; changed 2026-11-10). |
| Arrow keys | Swap left/right columns or swap rows up/down within a column, matching PaperWM semantics. |
| F | Toggle the focused window between tiled and floating. |
| C | Horizontally center the focused window and retile its Space. |
| S | Arrange the column on the left and the focused column across the two halves of the usable screen; no-op without a left column. Keep consistent gaps and valid geometry rather than preserving arithmetic defects. |
| L / H | Increase/decrease width by 10% of the usable layout canvas. |
| U / N | Increase/decrease height by 10% of the usable layout canvas, redistributing stacked windows through tiling. |
| I / O | Slurp a window into a column / barf it out into a separate column. |
| 1–9 | Dropped (2026-11-10): windows are moved between Spaces/displays with Mission Control, and Paperi follows. No public or working private API moves windows between Spaces on macOS 26, so a command would have to script Mission Control. |

Important details from the configuration:

- Despite the `focusWindowByTwo` name and comments, J/K pass **-1/+1**, so they move one column. The lookup tries the current row down toward row 1 in the destination column. Its second offset is identical to the first with these actual bindings. Do not implement a two-column jump.
- J/K never switch Spaces (changed 2026-11-10): at the end of the strip, on an empty Space or with an unmanaged window focused, they show an edge hint on the focused window. Replace the `hs.screen.mainScreen()` heuristic with explicit command/display ownership.
- A focus request gets one delayed retry after `hs.window.animationDuration`. Preserve reliable focus, but cancel a stale retry if a newer user command has selected another window.
- A separate unfiltered Hammerspoon window watcher calls `centerWindow()` on window creation and destruction. It centers whichever window is focused at callback time, not necessarily the event's window. Replace this with centering after an eligible managed-window insertion/removal in the affected layout. Popup events must never center the popup or an unrelated application window.
- SketchyBar calls and the Space watcher are commented out. There is no active SketchyBar integration to port.
- IPC CLI installation is active. It is supporting tooling, not a required window-management command; add a small diagnostic CLI later if useful.
- Inherited defaults include 8-point gaps, a 1-point screen margin, and normal visible titled standard windows with fullscreen windows excluded. Trackpad swipes, modifier dragging/lifting, and modifier scrolling are disabled. The inherited mouse-centering behavior around Space switching should also be characterized.
- Preserve horizontal virtual positions and edge clamping: macOS does not provide a general compositor API for freely placing other applications' windows arbitrarily offscreen. PaperWM's scrolling model keeps real windows constrained near the screen edges.

First release scope: these bindings, per-Space columns and stacked rows, native macOS tab groups, deterministic multi-display ownership, transient/popup isolation, floating windows, external focus changes, create/close/minimize/hide/fullscreen lifecycle, manual move/resize handling, display changes, native Space navigation, and following user Mission Control transfers. Three-finger trackpad scrolling (one slot per gesture) is the next feature after focus-scroll animation, below. Extensive preferences UI, scripting, and the rest of Hammerspoon are deferred.

## Next feature: realtime three-finger one-slot scrolling — planned 2026-11-10

Supersedes the earlier section-anchored paging stretch design (iOS-style viewport pages). The pure `Paging` helpers in `Layout.swift` are not used by this design; remove them once the new gesture ships.

### Interaction

- A **three-finger horizontal swipe** on the trackpad moves the strip of the display under the pointer. Windows follow the fingers continuously while they are down.
- Travel is limited to **one slot (column) per gesture**: at most the strip moves from the focused column's resting position to the resting position of its left or right neighbour, exactly the motion of ⌥⌘J/K. Finger travel beyond that is clamped with rubber-band resistance; it never continues into a second column. To move further, lift and swipe again (a new gesture may start while the previous one is still settling and continues from the current visual position).
- Reversal mid-gesture is allowed; the gesture can cross back through the start and towards the other neighbour, still bounded to one slot either side.
- On release: commit to the neighbour if progress ≥ a threshold (start at 0.5) or if a flick in that direction exceeds a velocity threshold; otherwise snap back. Commit = the same result as `focus left/right` (logical focus, reveal, raise + `AXMain` on the target). Settling reuses the timed focus-scroll animator from the current in-flight positions.
- No focus change, survey, or layout mutation while fingers are down. At a strip end (no neighbour) the strip moves with strong resistance and the existing edge hint flashes on release; no Space switching.
- Direction follows the content (fingers left → strip moves left → right neighbour comes in, like natural scrolling); a `gesture.invert` option flips it.
- Stacks: the target slot is `Layout.neighbor` (same row fallback as J/K). Native-tab containers move as one slot.
- If revealing the neighbour needs no scroll (it is already fully visible), the gesture still selects it: show the `swapHighlight`-style mask on the target as progress passes the threshold, and commit focus on release without moving windows.

### Design

1. **Pure gesture model (`PaperiCore`, unit-tested).** A `SlotSwipe` reducer: inputs `begin`, `move(dx, dy, t)`, `end`, `cancel`; outputs direction lock (horizontal intent after a small threshold, abandoned if vertical dominates), signed progress in −1…1 with rubber-band beyond the clamp, release velocity, and a decision `commit(.left/.right)` / `snapBack`. Progress is finger travel ÷ a configurable travel distance (fraction of the trackpad width, start ~0.25), independent of window widths, so every slot takes the same swipe.
2. **Separate renderers.** Keep the existing position-only `animateFocus` path for keyboard commands and external focus changes, regardless of snapshot configuration. Use the screenshot renderer from `experiment/snapshot-focus-scroll` only for swipes. Share target calculation and cancellation guards where useful; do not refactor keyboard animation into a new scheduler just to support gestures.
3. **Snapshot tracking.** Capture the background and strip windows at three-finger contact, then move their image layers directly from the latest progress, without implicit easing during contact. Compute both adjacent targets from copies of the starting layout. Real windows stay put during tracking and snap-back. The user found capture startup delay acceptable; measure it, but prioritize landing accuracy. Captured content remains frozen during contact. Screen Recording permission, missing captures, the existing 12-window cap and memory budget need explicit handling; retain keyboard operation if snapshots are unavailable. A finger-driven AX fallback is optional subsequent work, not required for this milestone.
4. **Release and handoff.** Snap-back returns images to the captured starting geometry without moving real windows. Commit changes logical focus once and places real windows under the overlay while images settle. Diagnose the reported end offset by recording capture geometry, intended targets, observed real frames and image-layer bounds. Check coordinate conversion, backing scale, shadows/content bounds, clamping and stale frames before choosing a correction. Require bounded stable observations and alignment between images and real windows before removing the overlay. Retarget images to observed geometry when appropriate; a visible correction slide can still be noticeable and is not automatically a fix. Ensure the following refresh does not move windows again. Bound the wait and always remove the overlay on failure, reporting an unconfirmed handoff.
5. **Interruption.** Cancel safely on mouse input, Space/display changes, pause/stop, Accessibility loss, popup/modal interaction, window destruction/resize or device removal. A new gesture during settling must start from the current visual state without exposing the previous target; this remains an explicit implementation task. Keyboard input during a swipe dismisses/reconciles its overlay before executing the existing keyboard path. Never leave a frozen overlay behind.

### Input capture

- **Primary backend: session event tap on gesture events (type 29), converted with `NSEvent(cgEvent:)` and `allTouches()`** — the path PaperWM's `swipe.lua` uses through Hammerspoon. It tracks touch identities and normalised positions; begin = exactly three new touches, end = finger count changes. Paperi already holds Accessibility, which covers an event tap. Run the tap on the main run loop, listen-only, never consuming events; re-enable it on `tapDisabledByTimeout`.
- **Fallback backend: `MultitouchSupport.framework` (private)** — `MTDeviceCreateList` + contact-frame callback; works regardless of system gesture settings and needs no extra permission, but is undocumented and needs device hot-plug handling. Only build it if the event tap proves unreliable on macOS 26 (touches missing, wrong finger counts, or events not delivered when Paperi is in the background). Keep both behind one `TouchSource` protocol so the reducer and motion code never see the backend.
- Verify on the built-in and a Magic Trackpad. Build it straight into live mode behind `gesture.enabled` with `-v` sample logging, not as a separate probe.

### Detecting system three-finger gestures

- Read with `CFPreferencesCopyAppValue` (after `CFPreferencesAppSynchronize`) from both `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad`:
  - `TrackpadThreeFingerHorizSwipeGesture` ≠ 0 (swipe between pages = 1, between full-screen apps/Spaces = 2) — direct conflict.
  - `TrackpadThreeFingerVertSwipeGesture` ≠ 0 (Mission Control / App Exposé on three fingers) — a diagonal swipe can trigger both.
  - `TrackpadThreeFingerDrag` ≠ 0 (Accessibility three-finger drag) — moves windows/selects text under the pointer.
  - `TrackpadThreeFingerTapGesture` (look up / data detectors) is harmless; ignore it.
- Any conflicting key on either domain → the Paperi gesture is **disabled**, `status` reports `gesture: {enabled: false, blockedBy: [...]}`, the menu shows a "Three-finger swipe disabled: …" item that opens Trackpad settings (`x-apple.systempreferences:com.apple.Trackpad-Settings.extension`), and the existing menu-bar popover shows a one-time warning at launch/reload (same mechanism as the display-arrangement warning). Paperi never changes the settings.
- Re-check at launch, reload, every gesture begin (cheap), and on a slow timer, so the gesture enables itself when the user turns system gestures off, and disables itself (with a warning) when they turn them on. A missing key is treated conservatively as a conflict (the factory default may put Spaces/Mission Control on three fingers); confirm the fresh-account defaults before relaxing this.
- Observed on this host 2026-11-10: all four three-finger keys are 0 in both domains (four-finger gestures remain on), so the gesture would be enabled.

### Configuration

`config.json` `gesture`: `enabled` (default false until validated, then true), `fingers` (3; 4 only when the four-finger system gestures are off — same detection with the `FourFinger` keys), `travel` (fraction of trackpad width per slot), `commitThreshold`, `flickVelocity`, `invert`. Validate like `focusScrollDuration`.

### Difficulty assessment

Overall: **medium-high, approximately four milestones rather than a time estimate.** Snapshot rendering avoids per-frame AX movement during contact, but capture correctness, final handoff, interruption and touch delivery remain unverified.

| Part | Difficulty | Risk / notes |
| --- | --- | --- |
| System-setting detection, warnings, config | Low | Key names verified on this host; defaults on a fresh account still to confirm |
| Pure swipe reducer (lock, clamp, rubber band, commit/snap decision) | Low | Fully unit-testable |
| Snapshot tracking and handoff | Medium-high | Preserve keyboard animator; resolve image/real-window alignment and mid-settle interruption |
| Event-tap touch capture | Medium, **uncertain** | Not yet verified that type-29 events carry touches to a background tap on macOS 26.7.2; fallback is a private framework |
| Realtime feel with real apps | Medium-high, uncertain | Image motion avoids per-frame AX writes; frozen content, capture bounds and landing accuracy need live validation |
| Cancellation / interaction with refresh, drag, Mission Control, Space switches | Medium | Same guards as focus animation; must be exercised live |

### Increments

1. **Detection + config + warning** (no capture yet): settings reader with unit tests over fixture dictionaries, `status` field, menu item, popover. Exit: warning shown when a three-finger key is turned on, cleared when off.
2. **Capture spike in live mode**: event-tap `TouchSource`, `-v` logging of begin/move/end with finger count and normalised dx; measure sample rate and background delivery. Decision point: keep the event tap or build the `MultitouchSupport` fallback.
3. **Reducer + snapshot tracking + settle**: keep keyboard animation unchanged; fix and validate screenshot handoff first, then wire progress, commit/snap-back, edge resistance and cancellation. Unit-test the reducer; live-test with Terminal/TextEdit/Finder.
4. **Live validation and tuning**: tracking, reversal, snap-back, flick, edge, mid-settle re-swipe, mouse-down cancel, Space switch mid-gesture, stacked and tabbed columns, two displays, slow app. Record tick cost, missed ticks, AX writes per frame and sample-to-write latency in `status`. Targets as below, measured not assumed.

### Gesture performance gate

Measure capture delay, input-to-displayed-image latency, displayed cadence, memory, release-to-real-window confirmation and landing error separately. Target responsive 60 Hz tracking initially with about five visible windows, then evaluate 120 Hz and larger workloads within capture limits. Layer updates alone do not prove displayed smoothness. Validate text sharpness, frozen content, offscreen captures, stacking, popup recovery, reversal, snap-back and repeat gestures. Verify keyboard commands still use the existing AX animator independently of swipes. Ship enabled-by-default only after reliable capture and handoff, with no keyboard or recovery regressions.

## Required improvements over the current setup

### Native macOS tabs

Treat a native tabbed window as one logical layout slot with an active window representative and, when discoverable, multiple underlying members. Switching tabs must retain the column, row, size, and virtual position; an inactive tab disappearing from the AX window list must not be interpreted as closing the whole slot. Browser content tabs are normally internal to one window and are a separate case.

Prototype actual AX and WindowServer event sequences for native tab creation, selection, closing the active/last tab, merge-all, detach, and dragging a tab to another display. Establish what identity/grouping information is available for each supported app. Do not group by title or equal geometry alone, and do not assume one reliable public cross-process tab-group API exists. Use bounded app-specific reconciliation where necessary. When association is ambiguous, leave the affected container untouched and report the unsupported case rather than duplicating tiles or moving hidden members.

Acceptance: the agreed native-tab apps keep exactly one layout slot per visible tab container through the operations above, including Space/display moves. Transfers must be verified for the whole group. Native tabs are an early feasibility gate, not deferred polishing; publish an app/OS support matrix if universal handling is unavailable.

### Consistent multi-display behavior

Use stable display UUIDs and runtime Space IDs, with an active Space and last managed focus per display. Numeric display/Space positions are presentation labels, not persistent identities. Rebuild topology after rearrangement, reconnect, wake, and Mission Control changes; do not persist Space IDs across login as if they were stable.

Proposed command policy: resolve a managed focused window or transient owner first; otherwise use the last managed display context, then the pointer display for a genuinely empty context. Do not derive the target from the primary display or the popup's location. J/K stays in that display's layout and shows an edge hint at its ends. It never implicitly jumps to a different monitor. Numbered Space moves were dropped; windows move between Spaces through Mission Control.

Each display uses its own usable frame, scale conversion, Dock/menu bar insets, layout anchor, and scroll position. A window crossing displays is removed from its old layout and inserted once into the confirmed destination. Hot-unplug reconciles with the windows' actual OS destinations rather than assuming macOS will restore former ownership; reconnect must not duplicate windows or unexpectedly pull them back.

Acceptance: focus/navigation, centering, resizing, transfers, and create/close events affect only the intended layout on two monitors, including negative origins, mixed scaling, changed primary display, and unplug/replug. Initially require “Displays have separate Spaces” enabled; detect the disabled/mirroring configurations and report the supported scope rather than silently applying inconsistent independent-display behavior.

### Popups, Control Center, sheets, and transient focus

Classify before any layout or centering effect. Distinguish **tiled**, **user-floating**, **transient/system-excluded**, and **pending/unknown**. Excluded popups are not user-floating windows and must never be enrolled through the floating toggle by accident.

Use owner bundle identity, AX role/subrole, parent/owner relationships, window level, move/resize capabilities, and available window metadata together. Explicitly exclude system overlays such as Control Center; menus, popovers, tooltips, sheets, and utility panels normally stay outside tiling. Allow narrowly scoped rules for nonstandard document windows and app-specific exceptions. Missing metadata stays pending with bounded retries; it does not imply eligibility. Neither a titlebar check nor a blanket rule for an entire app is sufficient.

Opening or dismissing Control Center must cause zero layout insertion/removal or centering effects, including centering a previously focused document. Maintain OS focus separately from last managed focus. While a menu/system overlay or modal sheet is active, suppress layout/focus/Space effects that would steal its focus; pass keys through where possible and scope suspension to the interaction or owner. After dismissal, resume automatically using current state, never replay stale effects. Other display layouts and observers remain alive. A deliberate floating document is still addressable by applicable commands.

The fourth reported pain point is that **a popup window blocks window management**. Treat this separately from incorrect popup centering: excluding a popup from tiling must not disable the manager, lose its managed focus context, or stall its event queue. The exact application and event sequence still need reproduction; no root cause has been established.

Keep transient interaction state separate from manager pause state. A popup may restrict operations on its modal owner while it is active, but must not globally suspend hotkeys, observers, layout processing, or commands targeting other eligible windows/displays. Re-evaluate command targets from current focus and ownership on every command; do not keep routing commands to a closed popup. Bound AX calls and retries per process so one unresponsive popup/app cannot block unrelated applications. On dismissal or owner termination, clear transient state and reconcile the affected layout automatically, including when a close notification is missing. Never require a manager restart or manual refresh for recovery.

Acceptance: open a popup, switch to another eligible window, and verify focus navigation, swaps, resize, and Space actions still work there while the popup remains open. Dismiss the popup and verify its owner becomes manageable immediately without replaying suppressed commands. Repeat with modal sheets, nonmodal utility windows, rapid open/close, owner termination, and a timed-out AX request. System menus may consume shortcuts while tracking; that temporary OS interaction must not turn into persistent manager suspension.

### What to learn from yabai

Yabai is an implementation reference, not a required runtime dependency or a replacement layout model. Retain Paperi's scrolling columns rather than adopting binary space partitioning.

- Its [window manager](https://github.com/asmvik/yabai/blob/master/src/window_manager.c) separates tracked windows from management eligibility and applies rules using app, title, role, and subrole. Adopt that separation plus an explicit classification reason for diagnostics.
- Its [window metadata](https://github.com/asmvik/yabai/blob/master/src/window.c) uses parent/root, role/subrole, capabilities, and levels, and resolves window display identity with a geometry fallback. Use these as inputs to a stricter transient policy, not a copied predicate.
- Its [display manager](https://github.com/asmvik/yabai/blob/master/src/display_manager.c) distinguishes primary, active, pointer-associated, and arrangement-based display concepts. Make those distinctions explicit in Paperi's command policy.
- Its [event handling](https://github.com/asmvik/yabai/blob/master/src/event_loop.c) is a reference for lifecycle and focus reconciliation. Instrument Paperi's own event pipeline and use bounded recovery rather than porting every workaround.
- Yabai's [requirements and caveats](https://github.com/asmvik/yabai#requirements-and-caveats) distinguish ordinary Accessibility operation from additional control through an optional injected scripting addition. Do not assume those privileged features are available in Paperi's no-injection design.

Evaluate building the focused native backend versus adapting a minimal, attributed subset of yabai's backend during the spike. Avoid a fork of its entire manager unless measurement demonstrates a substantial advantage; that would carry layout coupling, update burden, and features outside this scope. No claim of native-tab support is inferred from the reviewed yabai code.

## Architecture

```text
Hotkeys + AX/app/display/Space notifications
                  |
          Event normalization
                  |
        Serialized state reducer
                  |
       Pure layout + action engine
                  |
        Frame/focus/Space effects
                  |
       macOS adapters + feedback
```

| Component | Responsibilities |
| --- | --- |
| App shell | Menu bar controls, Accessibility onboarding, pause/resume, launch at login, diagnostics. Keep UI work on the main thread. |
| Window registry | Track physical windows independently of eligibility; classify transients, resolve native tab membership, and maintain logical container identity. Track OS focus separately from managed focus. Handle reused IDs, invalid AX refs, and pending metadata. |
| State/layout core | Display UUID → runtime Space → ordered columns → logical window/tab-container slots, desired sizes, virtual X positions, and per-layout focus anchor. Pure transitions produce desired frames and effects. |
| Scheduler | Serialize state updates, coalesce redundant notifications, mark affected Spaces dirty, cancel superseded effects. Keep synchronous AX calls off the UI path with bounded per-process work. |
| AX adapter | Discover and focus windows; read/write position and size; handle messaging timeouts, unsupported attributes, minimum sizes, and application-specific constraints. |
| Spaces adapter | Enumerate display/Space topology and membership, transfer windows, request navigation, and observe completion. Contain private API declarations and availability checks here. |
| Configuration | Versioned Codable JSON containing the current shortcuts and policies. Validate conflicts and preserve a last-known-good configuration. No arbitrary Lua execution required. |

Start with an Xcode app target and a Swift package for the core and its tests. Use AppKit for the small shell; a large settings UI is unnecessary. Keep any Objective-C bridge narrow enough to replace independently when macOS changes.

### Event and frame strategy

1. Discover existing windows once at startup, then update the registry incrementally. Reconcile on Space/display changes, wake, observer loss, or explicit refresh rather than scanning all applications per keystroke.
2. Apply each command to one authoritative state snapshot. Coalesce lifecycle bursts, but avoid adding an unconditional debounce delay to keyboard actions.
3. Calculate the affected layout using cached geometry and produce a frame diff. Only write changed attributes. A focus change can legitimately reposition many columns; incremental processing must not assume only one window changes.
4. Track requested and observed frames separately. Recognize expected AX echoes by window, frame tolerance, generation, and a bounded deadline. Keep real user moves/resizes observable instead of disabling all watchers throughout an animation.
5. Confirm application-constrained geometry and reconcile once as needed; bound retries to avoid layout oscillation. Queue newly created windows individually until their identity and Space resolve.
6. Classify first, then coordinate auto-centering with eligible logical-slot insertion/removal. Popup events and tab selection produce no insertion-triggered centering. One event burst produces one intended layout.
7. Process Space transfer as a transaction: validate destination, move, confirm membership, update both layouts, follow/focus, and recover state on failure. A late completion must not steal focus after a newer command.

## macOS feasibility and distribution

Use public Accessibility APIs for ordinary window control and NSWorkspace/display notifications for lifecycle. Expect Accessibility permission. Prefer registered global shortcuts for the fixed key set; use event taps only if necessary and determine any additional Input Monitoring requirement from the actual implementation. Do not request Screen Recording by default for a keyboard window manager; reassess if a chosen discovery or UI feature needs protected information.

Native Space control is the main compatibility risk. Hammerspoon uses private SkyLight/CGS functions for topology/membership and some moves; PaperWM also has Mission Control Accessibility/mouse automation. Public AX APIs alone do not expose full parity. Mapping an AX window to a WindowServer ID can itself require an undocumented bridge; include that in the early prototype.

Prototype on the actual OS before committing to a transfer backend. Prefer a working no-injection path and keep a Mission Control fallback asynchronous, timeout-bound, and isolated. Do not assume private functions will work simply because their symbols exist. Preserve the user's native Spaces; substituting application-managed workspaces would be a separate product decision.

Plan for direct distribution as a signed, notarized application outside the Mac App Store, without App Sandbox. Verify signing/notarization with the chosen private APIs. No SIP changes, root daemon, or Dock injection are part of the initial design. Unsupported Space operations should fail visibly while ordinary tiling remains usable.

Use one coordinate convention in the core and explicit conversions at AppKit/AX boundaries. Test negative display origins, mixed scaling, menu bar/Dock usable areas, and display disconnects. Native fullscreen, Mission Control, Stage Manager, and separate-Spaces settings need explicit compatibility tests, not assumptions.

## Performance investigation and targets

### Next milestone: focus-scroll animation and measurement — 2026-11-10

Develop animations alongside performance tuning, after basic instrumentation; completing all optimization is not a prerequisite. The agreed sequence is:

1. **Instrument the current path.** Measure discovery, native-tab reconciliation, layout calculation, and AX writes separately. Count AX calls and record command-to-first-motion and command-to-confirmed-stable-frame latency, establishing an animation-disabled baseline.
2. **Implement a minimal interruptible same-Space focus-scroll transition.** Calculate the final layout once per command and interpolate affected window positions toward it using a paced scheduler. Do not survey apps or recalculate layout on every animation frame. Start with a short configurable duration and an animation-off option. Focus changes that do not scroll the strip need no geometry animation. Creation, closure, dragging, and system Space transitions are outside this initial scope; trackpad scrolling is the separate milestone [below the bindings](#next-feature-realtime-three-finger-one-slot-scrolling--planned-2026-11-10).
3. **Tune the combined path.** Measure frame pacing, AX traffic, responsiveness, and final-frame accuracy with animation enabled and disabled. Reduce redundant surveys, retain fallback discovery, and isolate slow apps based on measured costs. Report intentional transition duration separately from processing overhead; retain the animation-disabled latency target below.

Interruption and correctness requirements:

- Repeated J/K commands retarget from the current in-flight position without snapping to the previous target or replaying queued transitions. Keep logical focus and final target authoritative; reject stale scheduler work using generations.
- Mouse interaction immediately cancels animation writes and returns control to the user. Preserve the existing no-frame-writes-while-held behavior.
- Track intermediate animation frames as expected AX effects so their move/resize notifications cannot be adopted as user resizes or trigger a feedback loop. Continue recognizing genuine external changes.
- Cancel safely on Space/display changes, pause/stop, window destruction, or lost eligibility. Confirm final geometry with bounded reconciliation, and prevent stale effects from applying after cancellation.
- A slow or unresponsive app must not stall motion for every other window. Validate the AX scheduling approach before committing to a smoothness target.

Acceptance: exercise repeated and reversed focus commands, no-scroll focus changes, mouse interruption, slow apps, lifecycle cancellation, and animation-off behavior. Verify final layout/focus and absence of stale writes or geometry-adoption loops. Start with a few visible real-app windows, then expand the workload. This milestone is separate from deciding create/destroy auto-centering and from the daily-use soak.


The installed code suggests these candidates for measurement:

- Tiling reads frames across a Space and performs Space queries; `moveWindow` reads the frame again before skipping unchanged work.
- Each changed frame stops its watcher and schedules restart after the animation duration plus 20 ms. Focus and pending-window handling also use animation-duration timers.
- The extra create/destroy centering watcher can cause a separate move and full retile alongside PaperWM's normal event handling.
- The Mission Control module contains a busy-wait helper. Trace its callers and timing during actual Space actions before attributing stalls to it.
- Hammerspoon already performs window operations in native code. Reducing AX traffic and redundant work is a more defensible performance hypothesis than blaming Lua alone.

Benchmark the existing configuration first, with its normal animations, and separately with animations disabled as a controlled comparison. Do not modify the user's live configuration as part of planning. Never run both managers against the same windows during a benchmark.

Record command receipt → layout calculation → AX writes → observed stable frames/focus using monotonic timestamps and signposts. Report system Space transition time separately. Measure p50/p95, AX calls and layout passes per command, CPU, resident memory, and correctness with 5, 20, and 50 windows. Include cross-app focus, repeated shortcuts, stacked columns, create/close bursts, and Space transfers; use Instruments to identify blocking AX clients.

Provisional targets, to revise after baseline measurement:

| Metric | Initial acceptance target |
| --- | --- |
| Core layout calculation | p95 under 1 ms for 50 cached windows. |
| Ordinary command to stable observed state | p95 under 50 ms for 20 responsive windows, with animation disabled; explicitly report apps that exceed this. |
| Idle CPU | Below 0.5% average over five quiet minutes on the test machine. |
| Native process memory | Under 100 MB resident for the agreed test workload. |
| Compared with current setup | Aim for at least 2× lower p95 ordinary-command latency; do not claim success from animation differences alone. |
| Stability | No persistent event loop, lost managed windows, or stale focus retries in the soak suite. |

## Delivery sequence

### Commit checkpoints

Commit autonomously when a coherent implementation milestone, validated fix or
useful investigation result is ready to preserve. Do not wait for a separate
user request or accumulate multiple completed increments unnecessarily. Before
committing, review the diff, run checks appropriate to the change and update the
status with the actual validation results and remaining limitations. Keep commits
focused, exclude scratch files and raw captures, and preserve unrelated user
changes. Commit messages must describe the concrete result without implying that
unverified behavior works. Pushing and publishing remain separate actions.

### Agreed implementation order — 2026-11-08

Build a limited ordinary-window path first, retaining logical tab-container slots
from the beginning. Per user direction on 2026-11-09, prioritize a working version
with proper native macOS tabs (including active-first admission without clicking
inactive tabs and lazy unvisited reconciliation), cross-Space transfers, and
multi-display/multi-Space support before global keyboard shortcuts. Clarified the
same day: that working version must manage real application windows (opt-in
allowlist, CLI-driven commands are acceptable); shortcuts follow once it shows
tabs, Spaces and multiple displays are resolved. Prefer extending live mode over
new disposable probes. See
[docs/STATUS.md](../STATUS.md) for the current capability matrix and handoff
instructions through increment 63.

1. Connect native discovery/events → lifecycle reducer → layout → confirmed AX
   effects, first on disposable windows. Creation/closure, focus, commands and
   external resize, plus transient/popup exclusion and recovery must work before
   offering an opt-in ordinary-window preview. Its initial scope is one confirmed
   display/Space. Unknown membership/presentation must withhold effects; missing
   enumeration is never closure. Production keyboard management stays off until
   that preview has an explicit opt-in scope and recovery path.
2. First prove standard AppKit native tabs in the disposable demo: create, switch,
   merge, detach, close-active and close-last. Use its native state only as a test
   oracle; the external adapter must discover membership independently. Connect
   confirmed membership to the shared session and effect path, then validate that
   path in Finder, Terminal and Preview before expanding unrelated features.
   A selected physical representative can change without logical insertion,
   geometry reset or insertion-triggered centering. Native-tab lifecycle is not
   deferred until an otherwise finished manager exists.
3. Expand real-app, display and recovery compatibility, then benchmark and soak.
   Space transfer is a separate feasibility track: the tested direct backend
   fails on this host; investigate the reference Mission Control alternative with
   a bounded disposable-window test rather than blocking ordinary placement.

Logical slot IDs are stable container identities, separate from physical window
IDs and AX references. Ordinary windows begin as one-member slots; only affirmative
membership evidence may update a container. The current fixture guarantee that
tabbing is disabled must not be generalized into a claim that arbitrary live
windows are known singletons. Uncertain native-tab windows remain unmanaged in
the limited preview until their adapter is verified.

### Overall milestones and final gates

1. **Behavior capture and baseline.** Record OS/hardware, displays, Space settings, commonly used apps, installed Hammerspoon version, animation settings, and upstream revisions. Create command/geometry traces covering every binding and lifecycle case. Resolve Space numbering, transfer behavior, and create/destroy centering timing. Exit: reproducible parity fixtures and baseline measurements.
2. **Native feasibility spike.** Build a menu bar app that obtains AX access, discovers/focuses/resizes windows, maps window IDs, and lists Spaces. Demonstrate cross-Space move-and-follow with SIP enabled and no injection, native-tab identity through selection/merge/detach, classification of Control Center and application popups, and command ownership on two displays. Compare an original backend with selectively adapted yabai patterns. Verify cancellation and error paths. Exit: the four platform risks—Spaces, tabs, classification, and display ownership—have demonstrated solutions or an explicit support limitation before expanding the app.
3. **Pure layout core.** Implement ordered columns/rows, logical tab-container slots, virtual positions, gaps, focus lookup, swaps, resizing, split, slurp/barf, and floating state. Use installed PaperWM traces for intended interactions, with new specification fixtures for corrected behavior; upstream output is not an oracle for known bugs. Exit: deterministic fixtures and invariants pass, including empty/single-window layouts, tab representative changes, transient focus, display ownership, and screen edges.
4. **Live keyboard parity and pain-point fixes.** Connect the scheduler, AX adapter, current shortcuts, guarded auto-centering, native tabs, Space transactions, and display/lifecycle observers. Add pause/resume and classification/state diagnostics. Exit: every active binding works in real applications, native-tab acceptance passes, two-display actions are deterministic, and popups neither move nor leave management suspended after dismissal.
5. **Focus-scroll animation, performance and resilience.** Instrument the immediate path, implement the minimal interruptible same-Space focus-scroll transition described above, then profile and tune the combined path with animation enabled and disabled. Reduce AX traffic, isolate slow apps, tune coalescing, and validate failures/recovery. Exercise sleep/wake, permission revocation, app termination, minimize/hide/fullscreen, display changes, rapid input, and Mission Control. Exit: parity checklist passes and benchmark results justify the performance claim.
6. **Daily-use release.** Add validated configuration reload, launch at login, signing/notarization, license notices, and installation/recovery documentation. Disable PaperWM's start call and its extra watcher/hotkeys before enabling Paperi, keeping a backup for rollback. Hammerspoon may remain available for unrelated tasks. Exit: an eight-hour daily-use soak and a working rollback procedure.
7. **Three-finger one-slot scrolling.** Detect conflicting system three-finger gestures (disable and warn), capture touches with an event tap (private multitouch fallback only if needed), drive the focus-scroll scheduler from finger progress bounded to one slot, and settle by commit or snap-back. Exit: the increments and performance gate in [the gesture section](#next-feature-realtime-three-finger-one-slot-scrolling--planned-2026-11-10) pass; otherwise keep it opt-in and document unsupported devices/apps.

Milestones are ordered by dependencies, not calendar estimates. The first deliverable is the baseline and a small feasibility spike addressing Space transfers, native tabs, popup exclusion, and multi-display ownership. All are release gates; performance work follows a correct behavioral model.

## Verification

- Unit and property tests: each window belongs to at most one tiled position, empty columns disappear, indices remain consistent, dimensions stay valid, row fallback matches J/K, virtual order is preserved, and stale effects cannot overwrite a newer action.
- Fixture comparisons: intended geometry for split, resize, slurp/barf, and swaps; use explicit new expectations for corrected bugs and avoid reproducing implementation-specific event ordering.
- Adapter tests with simulated events: missing Space on creation, notification reordering, duplicate notifications, constrained sizes, invalid window refs, failed/late transfers, observer failure, and timeouts.
- Native-tab regression matrix: create/switch/close tabs, close last tab, merge/detach, move container across Spaces/displays, and verify no duplicate or lost slots.
- Popup regression matrix: Control Center, menu bar popovers, context menus, file dialogs/sheets, and app utility panels. Verify zero unexpected centering or Space jumps, continued management of other eligible windows while a popup is open, and automatic owner recovery after dismissal without restart/manual refresh. Capture the user's exact blocking reproducer during baseline collection.
- Display regression matrix: two active displays with independent Spaces, changed primary monitor, negative origins, mixed scales, moving windows across the boundary, sleep/wake and unplug/replug. Verify only the intended layout changes and no duplicate ownership.
- Manual integration matrix: the user's daily apps plus representative AppKit, Electron, browser, and terminal windows; fullscreen and empty Spaces; publish native-tab and special-window support limitations by app/OS.
- Benchmarks and soak results remain separate from unit-test success. A fast layout calculation alone does not establish a faster window manager.

## Open source references and reuse

Both requested projects are open source under MIT:

- [PaperWM.spoon source](https://github.com/mogenson/PaperWM.spoon) and [license at the inspected revision](https://github.com/mogenson/PaperWM.spoon/blob/f86f76bae635307d6cb12c8d66693acff57cf82a/LICENSE).
- [Hammerspoon source](https://github.com/Hammerspoon/hammerspoon) and [MIT license](https://github.com/Hammerspoon/hammerspoon/blob/master/LICENSE).
- [Yabai source](https://github.com/asmvik/yabai) and [MIT license](https://github.com/asmvik/yabai/blob/master/LICENSE.txt); pin the reviewed implementation before adapting code and preserve its notices.
- Hammerspoon [window bridge](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/window/libwindow.m), [native Spaces bridge](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m), and [Spaces Lua layer](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua).
- [Hammerspoon Spaces API documentation](https://www.hammerspoon.org/docs/hs.spaces.html) explains private API and Accessibility caveats.

MIT permits reuse and adaptation with the required copyright and permission notices. Preserve notices for copied or substantially adapted algorithms as well as native bridge code, and audit separately licensed dependencies if any are imported. Pin the exact Hammerspoon revision before reusing code. Publishing Paperi under MIT is a reasonable proposed choice; no project license has been added by this planning draft.
