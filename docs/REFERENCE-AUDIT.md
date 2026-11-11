# Source-led feasibility checkpoint — 2026-11-08

This comparison replaces further open-ended diagnostic refinement as the next
development direction. Source behavior is distinguished from behavior verified
on this host. It does not declare the platform release gates complete.

## Reproducible references

- PaperWM.spoon: `f86f76bae635307d6cb12c8d66693acff57cf82a`, the revision identified
  in the original plan as installed. This audit does not re-inspect the user's live configuration.
- Hammerspoon: `23e387e2805a9890066366e0ac96c71b27f0cfd5`, resolved upstream HEAD.
  It is not asserted to match the installed binary.
- yabai: `dd845723416f5fe92af49fad5ebab00369e07edd`, resolved upstream HEAD.

Downloaded reference files are ignored build inputs under `.build/reference-audit/`.
Only the small probe adapts source; its license is in [third-party notices](../THIRD_PARTY_NOTICES.md).

## Mechanisms and decisions

| Behavior | Reference mechanism | Paperi decision |
| --- | --- | --- |
| Initial inventory | PaperWM asks Hammerspoon's window filter for windows. yabai starts with AXWindows and nonzero physical IDs. | Continue using physical IDs and fresh AX references; stop treating complete structural tab inventory as a prerequisite for an ordinary-window prototype. |
| Startup failure | Hammerspoon retries creation events without IDs. yabai retries observer attachment after cannotComplete and separately refreshes unresolved applications. | Keep bounded retries and explicit unavailable state. Further diagnostic expansion needs a concrete failed behavior it can resolve. |
| Inactive-Space windows | yabai compares WindowServer/Space inventory with AX enumeration, then uses a private remote-token element search for missing references. | This explains why AXWindows alone is weaker. Do not introduce token brute force in the first supported ordinary-window slice; undiscovered inactive-Space windows remain an explicit limitation. |
| Native tabs | Installed PaperWM rejects affected Apple windows when tabCount exceeds one; Hammerspoon exposes tab count/selection rather than a persistent physical-member container model. | Native-tab containers are an enhancement beyond this PaperWM baseline. Keep the experiment, but do not make exhaustive tab learning block a clearly limited ordinary-window prototype. Full tab support remains a release requirement until explicitly revised. |
| Placement | PaperWM skips unchanged frames and stops/restarts its window watcher around setFrame. Hammerspoon's current setter uses size → position → size and temporarily handles Enhanced UI. | Prototype immediate, confirmed AX frame writes on one eligible fixture first. Preserve observed/requested separation when integrating; do not silently copy watcher suppression into the scheduler. |
| Popups | PaperWM delegates filtering/visibility events to Hammerspoon. yabai combines root/role/subrole checks with separate menu-open/close handling for focus-follows-mouse. | These are concrete patterns, not proof of the user's cross-display popup recovery. Test actual popup ownership/focus separately; avoid a global management pause. |
| Space move | Installed PaperWM's command uses its Mission Control helper to find a window and drag it to a Space, then confirms membership. Hammerspoon's direct API and yabai have private non-injected transfer paths. | First isolate direct membership transfer in a disposable own-window executable; activation/follow and live registry transactions remain separate work. |
| Space follow/display ownership | PaperWM resolves destination display and checks allowed screens, then retries focus. | Use display UUID/runtime Space ownership with bounded confirmation. This host still cannot verify two independent displays. |

### Source anchors

yabai also explicitly documents native NSDocument tabs (including Finder and
Terminal) as a known problem when creating tabs, recommending avoidance or floating
rules. Its layout stacks are not proof of native document-tab grouping support.
See the pinned [README caveat](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/README.md#L54).

- PaperWM [window refresh and tab rejection](https://github.com/mogenson/PaperWM.spoon/blob/f86f76bae635307d6cb12c8d66693acff57cf82a/windows.lua#L105),
  [frame setter wrapper](https://github.com/mogenson/PaperWM.spoon/blob/f86f76bae635307d6cb12c8d66693acff57cf82a/windows.lua#L742),
  [Space transaction](https://github.com/mogenson/PaperWM.spoon/blob/f86f76bae635307d6cb12c8d66693acff57cf82a/space.lua#L64),
  [Mission Control drag/follow](https://github.com/mogenson/PaperWM.spoon/blob/f86f76bae635307d6cb12c8d66693acff57cf82a/mission_control.lua#L190),
  [event subscriptions](https://github.com/mogenson/PaperWM.spoon/blob/f86f76bae635307d6cb12c8d66693acff57cf82a/events.lua#L364).
- Hammerspoon [window creation retries](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/window/window_filter.lua#L1376),
  [frame setter and tab helpers](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/Hammerspoon/HSuicore.m#L748),
  [direct Space movement](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/spaces/libspaces.m#L156).
- yabai [inventory and private-token fallback](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window_manager.c#L1546),
  [Space transfer backends](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/space_manager.c#L665),
  [root/role policy](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.c#L1031),
  [observer retry](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/event_loop.c#L146),
  [menu handling](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/event_loop.c#L1564).

## Implemented vertical slice: own-window Space round trip

> Removed 2026-11-10: Paperi no longer moves windows between Spaces (users do it
> in Mission Control and live mode follows), so `PaperiSpaceProbe` was deleted.
> The sections below are kept as the record of what was measured.

`PaperiSpaceProbe` is a separate executable, not linked into the production app.
It creates one disposable window, reads its exact membership, selects another
existing user Space on the same display, submits a move, polls for destination
membership, requests return, confirms source membership, and closes the window.
It accepts no external window ID. No documents, settings, Space creation,
Space activation, focus writes, Dock injection or SIP changes are involved.

The dispatch adapts yabai's bridged operation and compatibility-workspace fallback.
The latter temporarily assigns a compatibility ID to the destination, submits the
window workspace assignment and resets that ID to zero, following the references.
The compatibility setter's return type differs among private declarations, and the
reference callers ignore it. Schema 2 therefore does not interpret its return
register as a documented error code or gate workspace assignment on it. Where
available, the compatibility getter records the marker before/after assignment,
and the previous marker is restored. The workspace assignment return is retained
as raw evidence. Submission alone is never treated as a successful move.
Each membership wait is bounded to about three seconds plus query time. A timeout
still attempts return, and the disposable window is closed on completion.

```sh
./scripts/swift.sh build --product PaperiSpaceProbe
./scripts/swift.sh run --skip-build PaperiSpaceProbe
```

Exit 0 means confirmed round trip; 1 means transfer failure; 2 means missing
prerequisites/unsupported environment. The executable may briefly show its window.
The first probe exposed that AppKit termination exited before main returned its
status; the final implementation exits explicitly after reporting and cleanup.

### Host result and next decision

On macOS 26.7.2, the new bridged entry point is absent; compatibility-workspace
symbols are present. The fixture starts on Space 237, type 4 (fullscreen), while
that display exposes only one user Space (ID 1). The probe exits unsupported
with status 2 before any transfer submission. This is
an environment prerequisite, not evidence that the backend failed or worked.
The final local JSON capture is `captures/space-probe-source-type.json`.

Next: run this probe from a normal desktop with two existing user Spaces. Do not add more tab diagnostics
while waiting. Then implement a fixture-scoped ordinary-window AX placement slice,
followed by a gated opt-in live ordinary-window path. This experimental progression
does not authorize enabling management before the existing release gates or silently
reduce the requested final feature set. Native tabs, actual popup recovery, follow,
cross-display ownership, baseline timing and daily-use validation remain open.

### Follow-up with prerequisites met

The environment now exposes user Spaces 1 and 378 and the probe starts on Space 1.
The initial probe incorrectly gated the workspace call on the compatibility
setter's assumed return value. Its earlier 5812615 result does not establish a
documented API rejection; that conclusion is superseded.

The corrected source-faithful sequence does attempt workspace assignment.
Compatibility getter values remain 0 before assignment, after assignment and
after restoration; workspace assignment returns 1006. Destination membership is
not observed within the bounded wait: the window remains on Space 1. Source
membership is observed after the return request, but that is not a successful
return transfer because the outbound move never succeeded. The disposable window
closes and the probe exits 1. Capture: `captures/space-probe-membership-check.json`.

This establishes a failed compatibility-path transfer on this host, without
attributing it to SIP, signing or a specific privilege. The bridged entry point
remains absent. Treat this backend as unavailable for the current prototype;
the next transfer alternative is the installed PaperWM Mission Control path,
which needs a separate explicit, bounded own-window interaction test. Ordinary
AX placement work can proceed independently; no more blind direct-transfer repeats.

### Mission Control transfer round trip verified

Increment 58 adds `--backend mission-control` and `--backend drag-switch` to
`PaperiSpaceProbe` (schema 3). Both act only on the probe's own disposable window,
release any held mouse button and restore the cursor on exit.

- `drag-switch` reads `com.apple.symbolichotkeys` (`79`/`81`) without modifying
  preferences. Both Move-a-space shortcuts are disabled on this host, so it exits
  unsupported (`2`) before posting input (`captures/space-probe-drag-switch-final.json`).
- `mission-control` adapts installed PaperWM's Dock `mc` / `mc.display` /
  `mc.windows` / `mc.spaces.list` AX traversal with two macOS 26.7.2 fixes:
  hovering directly over the target thumbnail to expand the collapsed Spaces bar
  (`y = -20` → `y = 87`) and waiting for the expansion animation to settle, then
  re-reading the destination thumbnail center during the drag before dropping
  (the bar's thumbnails shift by ~73 points on subsequent Mission Control entries
  while a window is dragged near the top edge). It identifies the probe window by
  an exact per-run UUID title and requires the thumbnail count to match the
  display's `SLSCopyManagedDisplaySpaces` entry count before dragging.
- Debug and release native runs both pass (`0`): outbound moves the probe window
  from Space `1` to `378` and switches the active Space to `378`; return moves it
  back to `1` and switches the active Space back to `1`, with both legs confirmed
  by `SLSCopySpacesForWindows` (`captures/space-probe-mission-control-debug.json`,
  `captures/space-probe-mission-control-release.json`). This proves a working
  no-injection cross-Space transfer and follow mechanism on this host for an owned
  disposable window; wiring it into live session transactions and native-tab
  containers remains ahead.

### Placement slice verified

Increment 42 implements `paperi probe-placement`: a newly launched disposable
child is matched by PID and physical window ID, checked through the existing
eligibility policy, then receives a pure-core frame via AX size → position → size.
Both debug and release native runs confirm the requested frame and restoration
exactly, with all six writes successful. No existing user window is targeted.
This establishes a small working geometry path while leaving lifecycle integration,
native tabs, popup recovery and Space transfer open. See [current status](STATUS.md).

Increment 43 connects native create/destroy notifications to that reducer/effect
path for two new non-tabbing fixture windows. Debug and release both verify
1→2→1→0 logical slots, confirmed reflow of the survivor after the left window
closes, matching physical identities and clean native-source teardown. This is
the creation/closure subset of the [agreed implementation order](archive/PLAN.md#agreed-implementation-order--2026-11-08),
with focus/commands/external resize and transient recovery still to implement.

Increments 44–45 add observed horizontal resizing and focused width-command
dispatch. The own-window interaction fixture verifies document/panel/document
focus, apply/discard/apply command results, unchanged logical containers and no
deferred replay in debug/release. Its omitted utility panel is recovered through
fresh focus/main references before transient classification. These results are
per-app fixture behavior; they do not close global active-app, real OS popup,
cross-display, keyboard registration or native-tab acceptance gates.

Increment 46 extracts an app/Space-scoped session shared by the native fixture
adapters. Admission defaults to withholding unknown tab membership, command
ownership defaults to the actual frontmost app, and stop invalidates old work
tickets and frame expectations. The fixture explicitly selects application-local
ownership. Native interaction and resize checks remain passing. Native geometry
restoration and observer shutdown remain adapter responsibilities; no general
user-window preview is enabled by this extraction.

Increment 47 adds controlled adapter cleanup: invalidate management, stop native
observation, then restore and confirm saved surviving-window frames under fresh
identity/Space/eligibility checks. Debug/release stop-while-open tests restore two
live fixture windows exactly, reject stale work and avoid repeated-stop writes.
Normal close-to-empty cleanup also remains passing. This establishes controlled
recovery only; abrupt termination and user-window preview recovery are still open.

Increment 48 exposes that scoped adapter as `paperi preview-fixture`, with local
AppKit buttons/key equivalents, frontmost command ownership and Stop/restoration.
The debug/release input test invokes grow/shrink key-equivalent handlers and the
actual Stop button, confirming effects and restoration without posting global
keyboard events. The preview remains restricted to two fresh non-tabbing windows.
This is enough of the ordinary-window interaction path to resume the early
real-app native-tab spike before adding unrelated features; general user-app
admission and native-tab safety are not inferred from the preview.

Increment 49 begins the real-app track with scoped temporary-folder Finder
documents and one New Tab menu action. Both document IDs are discoverable and
eligible; New Tab changes the active physical representative. The native tab bar
is a direct window child with AXTabs containing two AXTabButton radio controls,
but both controls point to the active representative. General DFS capture spends
its bounds on Finder content, so association learning remains unavailable. This
supports a shallow app-specific capture following the Hammerspoon direct-child
pattern, followed by selection/identity validation; it does not justify assuming
membership or enabling Finder geometry management yet.
