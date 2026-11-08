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
