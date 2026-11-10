# Paperi

Draft plan for a standalone macOS scrolling window manager that reproduces this user's PaperWM.spoon workflow with lower latency and resource use.

Implementation has started. See [current status](docs/STATUS.md), [development instructions](README.md), and [feasibility protocol](docs/FEASIBILITY.md). Release gates below remain open until verified; an in-memory tab-slot model does not establish working native-tab discovery.

## Recommendation

Build a native Swift menu bar app using AppKit, Accessibility observers, and a small Objective-C/C adapter for private window/Spaces APIs. Keep the layout engine independent of macOS APIs. Start with keyboard-driven parity and immediate frame changes; add animation only after measuring performance.

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
| J / K | Focus the adjacent left/right column using the custom row lookup; switch to the adjacent Space when there is no target. |
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
- Empty Spaces and fullscreen focused windows invoke adjacent-Space navigation. Navigation stops at the ends; it does not wrap. The current fallback also treats every unmanaged popup as a reason to switch Spaces; replace that with the transient-focus policy below. Replace the `hs.screen.mainScreen()` heuristic with explicit command/display ownership.
- A focus request gets one delayed retry after `hs.window.animationDuration`. Preserve reliable focus, but cancel a stale retry if a newer user command has selected another window.
- A separate unfiltered Hammerspoon window watcher calls `centerWindow()` on window creation and destruction. It centers whichever window is focused at callback time, not necessarily the event's window. Replace this with centering after an eligible managed-window insertion/removal in the affected layout. Popup events must never center the popup or an unrelated application window.
- SketchyBar calls and the Space watcher are commented out. There is no active SketchyBar integration to port.
- IPC CLI installation is active. It is supporting tooling, not a required window-management command; add a small diagnostic CLI later if useful.
- Inherited defaults include 8-point gaps, a 1-point screen margin, and normal visible titled standard windows with fullscreen windows excluded. Trackpad swipes, modifier dragging/lifting, and modifier scrolling are disabled. The inherited mouse-centering behavior around Space switching should also be characterized.
- Preserve horizontal virtual positions and edge clamping: macOS does not provide a general compositor API for freely placing other applications' windows arbitrarily offscreen. PaperWM's scrolling model keeps real windows constrained near the screen edges.

First release scope: these bindings, per-Space columns and stacked rows, native macOS tab groups, deterministic multi-display ownership, transient/popup isolation, floating windows, external focus changes, create/close/minimize/hide/fullscreen lifecycle, manual move/resize handling, display changes, native Space navigation, and following user Mission Control transfers. Direct trackpad scrolling is an explicit stretch goal below. Extensive preferences UI, scripting, and the rest of Hammerspoon are deferred.

## Stretch goal: direct three- or four-finger trackpad scrolling

Provide an opt-in, configurable **three- or four-finger horizontal gesture** for **section-anchored paging**, like the iOS Home Screen. Movement follows the fingers during contact, but resting positions are discrete section anchors. A release either returns to the current section or completes a transition to another section. This intentionally differs from PaperWM's continuous strip scrolling; arbitrary offsets and individual column centers are not the resting model.

Proposed section model: within each display's native Space, group consecutive whole columns into viewport-sized sections, with stacked rows and native tab containers kept together. Pack columns without changing their preferred widths; a section may contain one wide column or several narrower columns, with unused space allowed. Oversized columns use the existing usable-width constraint. Sections are layout pages, not additional macOS Spaces. This grouping policy is a starting design to validate, not a requirement to make each column its own page.

Keep section membership stable during a gesture and settle animation. Recompute at safe boundaries after insertion/removal, resizing, or display changes, preserving the focused logical slot and its section where possible. Track a committed section ID separately from the temporary drag offset; keyboard focus actions reveal the containing section when paging mode is active.

Proposed interaction:

- Lock the gesture to the pointer's display and its active managed Space at gesture start; preserve that ownership until completion. Do not switch displays because a window or pointer crosses a boundary mid-gesture.
- Recognize horizontal intent after a small configurable threshold. Preserve vertical/system gestures and ordinary two-finger application scrolling. Keep direction/natural scrolling, sensitivity, and finger count configurable.
- During the gesture, translate the layout's virtual horizontal offset from accumulated finger displacement. Preserve columns, stacked rows, native-tab slots, and relative gaps; clamp real window frames using the same backend constraints as keyboard scrolling.
- On release, choose a section using displacement and velocity thresholds, then animate to its exact anchor. A short slow drag returns to the current section; sufficient travel or a directional flick commits the adjacent section. Start with one-section flicks; long deliberate drags may traverse further sections. Avoid unbounded inertial scrolling across columns. Provide edge resistance and allow a new gesture to interrupt settling from the current visual offset.
- Avoid repeated focus changes while fingers move. After settling, restore the destination section's last eligible focus or choose a deterministic eligible slot, while respecting active modal/transient interactions. Do not trigger native Space navigation at section-strip edges by default; retain it as a separate keyboard behavior.
- Cancel cleanly on display/Space changes, sleep, permission loss, or conflicting popup/modal interaction. Cancel pending animation and reconcile current frames without replaying stale gesture effects or leaving management paused.

### Gesture feasibility and performance gate

Feasibility assessment assuming system three-/four-finger gestures are disabled: **continuous finger-following scrolling is achievable in principle; iOS-like frame consistency across arbitrary application windows is not guaranteed.** PaperWM already [captures touch identities and continuous normalized motion](https://github.com/mogenson/PaperWM.spoon/blob/main/swipe.lua), so input is supported by an existing implementation path, subject to validation on the target OS/device. Disabling conflicting system gestures removes arbitration pressure, but does not by itself guarantee the capture API's availability or permission behavior.

The main performance risk is moving real windows across processes, not calculating a scroll offset. During contact, change position only, keep sizes fixed, and bypass per-window easing animations. At 60 Hz the entire update budget is about 16.7 ms; at 120 Hz it is 8.3 ms. As an illustrative budget rather than a measurement, 20 sequential position writes averaging 1 ms each already exceed a 60 Hz frame before other work. Different applications may acknowledge updates at different times, producing visible skew even when average CPU use is low.

Optimize for the number of physically changing windows, not total registered windows: update visible and entering/leaving windows, and skip unchanged edge-clamped windows. Keep logical positions for all columns. Coalesce to the newest offset, never queue every touch sample, and isolate slow applications with bounded per-process work. Verify occlusion and edge behavior before skipping a window; do not leave a stale frame that could become visible. A small visible set is a plausible smooth-use case; many simultaneously moving windows, slow AX clients, and high-refresh displays are harder workloads. Treat these as hypotheses until benchmarked.

First validate live movement of roughly 3–5 visible windows at 60 Hz, then expand the stress matrix. The 20-window/60 Hz target below is aspirational, not a prerequisite for proving the interaction or a promised capability. If the AX backend cannot meet the desired feel, evaluate an isolated compositor-assisted backend separately; do not assume yabai's optional privileged animation facilities fit the no-injection constraint.

Prototype global finger-count and continuous-motion capture before promising support. Evaluate public event APIs first; an AppKit swipe event alone must not be assumed to provide global raw multi-touch tracking. If reliable capture requires a private multitouch interface, isolate it behind an optional adapter, document OS/device support and actual permission needs, and keep the keyboard manager independent. References: Apple's [swipe event](https://developer.apple.com/documentation/appkit/nsevent/eventtype/swipe) and [global event monitor](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)) documentation. Inspect the installed PaperWM swipe adapter as another candidate implementation reference during this prototype.

Three-/four-finger gestures may conflict with Mission Control, native Space swipes, App Exposé, and Accessibility three-finger dragging. Detect or document conflicts, let the user choose an available gesture, and never silently change system settings. Confirm whether the selected backend can claim the gesture without simultaneously activating a system action; observing motion alone is insufficient.

Use cached gesture-start layout geometry and a display-paced update loop. Keep only the newest pending offset, skip unchanged/clamped frames, bound per-app AX work, and reconcile external changes without a full discovery scan per sample. Measure actual physical window movement: smoothing an overlay while real windows lag does not meet the goal. Accessibility writes across many applications are not atomic compositor transforms, so iOS-level smoothness remains a measured ambition.

Acceptance: on built-in and external supported trackpads, demonstrate live tracking, reversal, short-drag snap-back, committed section transitions, velocity-based flicks, exact anchor settling, interruption, and cancellation with 5/20/50 windows, two displays, tabbed containers, and popups. Verify stable section membership during interaction and correct regrouping afterward. Measure input-to-observed-motion p50/p95, frame cadence/dropped updates at the display's refresh rate, AX writes, and CPU. Aim initially for p95 motion latency below 33 ms with 20 responsive windows and at least 60 Hz observed updates on a 60 Hz display; report hardware/app limits honestly. Ship this stretch goal only if gesture ownership is reliable and it does not regress keyboard latency or popup recovery.

## Required improvements over the current setup

### Native macOS tabs

Treat a native tabbed window as one logical layout slot with an active window representative and, when discoverable, multiple underlying members. Switching tabs must retain the column, row, size, and virtual position; an inactive tab disappearing from the AX window list must not be interpreted as closing the whole slot. Browser content tabs are normally internal to one window and are a separate case.

Prototype actual AX and WindowServer event sequences for native tab creation, selection, closing the active/last tab, merge-all, detach, and dragging a tab to another display. Establish what identity/grouping information is available for each supported app. Do not group by title or equal geometry alone, and do not assume one reliable public cross-process tab-group API exists. Use bounded app-specific reconciliation where necessary. When association is ambiguous, leave the affected container untouched and report the unsupported case rather than duplicating tiles or moving hidden members.

Acceptance: the agreed native-tab apps keep exactly one layout slot per visible tab container through the operations above, including Space/display moves. Transfers must be verified for the whole group. Native tabs are an early feasibility gate, not deferred polishing; publish an app/OS support matrix if universal handling is unavailable.

### Consistent multi-display behavior

Use stable display UUIDs and runtime Space IDs, with an active Space and last managed focus per display. Numeric display/Space positions are presentation labels, not persistent identities. Rebuild topology after rearrangement, reconnect, wake, and Mission Control changes; do not persist Space IDs across login as if they were stable.

Proposed command policy: resolve a managed focused window or transient owner first; otherwise use the last managed display context, then the pointer display for a genuinely empty context. Do not derive the target from the primary display or the popup's location. J/K stays in that display's layout and navigates that display's adjacent native Spaces at an edge. It never implicitly jumps to a different monitor. Numbered Space moves were dropped; windows move between Spaces through Mission Control.

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
[docs/STATUS.md](docs/STATUS.md) for the current capability matrix and handoff
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
5. **Performance and resilience.** Profile against the baseline, reduce AX traffic, isolate slow apps, tune coalescing, and validate failures/recovery. Exercise sleep/wake, permission revocation, app termination, minimize/hide/fullscreen, display changes, rapid input, and Mission Control. Exit: parity checklist passes and benchmark results justify the performance claim.
6. **Daily-use release.** Add validated configuration reload, launch at login, signing/notarization, license notices, and installation/recovery documentation. Disable PaperWM's start call and its extra watcher/hotkeys before enabling Paperi, keeping a backup for rollback. Hammerspoon may remain available for unrelated tasks. Exit: an eight-hour daily-use soak and a working rollback procedure.
7. **Stretch: section-anchored trackpad paging.** Prototype global three-/four-finger capture and system-gesture arbitration, validate stable section grouping, then connect finger-following offsets to a display-paced frame scheduler with threshold-based page selection and anchor settling. Exit: the gesture acceptance matrix and measured motion targets above pass; otherwise retain keyboard operation and document the unsupported gesture/backend combinations.

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
