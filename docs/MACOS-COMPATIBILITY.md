# macOS compatibility and gesture handling

While the swipe's fingers are on the trackpad, Paperi stops the app under the cursor from also reacting. macOS still sends ordinary scroll events while three fingers move, and Chromium-based apps (Chrome, ChatGPT Atlas and others) turn them into a back/forward swipe or a page scroll. From the moment the swipe's fingers touch until every finger has lifted, Paperi withholds scroll events and their momentum, pinch, rotate, smart-zoom, page-swipe and raw touch events from apps. A scroll or gesture that began before the extra finger landed still gets its end event, so no app is left mid-gesture. Two-finger gestures, mouse wheels, and system gestures that use more fingers than the swipe (four-finger Spaces and Mission Control swipes, four- and five-finger pinches) are not affected. Once an extra finger lands, the sequence is left to macOS until every finger lifts, and a Paperi swipe already under way is cancelled without moving the strip.

> **Warning: this relies on a private Apple framework and may break after a macOS update.** Paperi counts the fingers on the trackpad through the undocumented `MultitouchSupport.framework`, loaded at runtime in `Sources/PaperiBridge/PaperiBridge.c`. The code assumes the private contact-record layout it found there (96-byte stride, finger state at offset 20, states 3–4 meaning "touching"); Apple can change any of this without notice. Verified on macOS 26.7.2 (arm64), built-in trackpad, on 2026-11-10.
>
> - **If the framework or its functions are missing**, nothing is blocked: two-finger app gestures run alongside swipes again, as before this feature. The swipe itself does not depend on it. With `--verbose` the log says `no trackpad finger source; app gestures are not blocked`.
> - **If the record layout changes**, finger counts are wrong. Then app gestures leak through during swipes (counts too low), or ordinary two-finger scrolling stops working while Paperi runs (counts too high). If scrolling breaks after an OS update, set `"gesture": {"enabled": false}` and reload, or quit Paperi, then report it.
> - Trackpads are looked up only when the swipe gesture starts (launch, resume, reload, or a change of system gesture settings). A Magic Trackpad connected later is not covered until one of those happens.
> - With `--verbose`, each swipe logs `app gestures blocked (3 fingers down)` and `app gestures released (dropped N events)`.

## Private macOS interfaces

> **Warning: Paperi depends on private Apple interfaces that any macOS update may change or remove.** Apple documents none of them. All are loaded at runtime in `Sources/PaperiBridge/PaperiBridge.c`, so a missing one never stops Paperi from launching. Verified on macOS 26.7.2 (arm64) on 2026-11-10.

| Interface | Used for | If a macOS update breaks it |
| --- | --- | --- |
| **SkyLight** (`SLSCopyManagedDisplaySpaces`, `SLSCopySpacesForWindows`, `SLSSpaceGetType`, `SLSGetActiveSpace`, `SLSMainConnectionID`) | Each display's Spaces, which Space each window is on, desktop vs full-screen Spaces, the active Space | Live mode cannot work. Paperi **pauses** and shows “Paperi paused: macOS compatibility” with the reason (menu, popover, `paperi msg status` → `problem`). Windows stay where they are. It re-checks every 5 s and resumes by itself if the problem clears. |
| **`_AXUIElementGetWindow`** | Matching accessibility windows to window-server IDs | If the function is gone, Paperi pauses as above. If it still exists but returns 0, those windows are just never managed. `paperi check-apps` shows why. |
| **MultitouchSupport** | Counting fingers so app gestures are blocked during swipes | Blocking stops (or, with a changed data layout, two-finger scrolling may be withheld). See the warning above. |

Only read-only queries are used. Apple has already restricted the SkyLight calls that *change* state, which is why Paperi has no move-to-Space command (`SLSMoveWindowsToManagedSpace` fails on 26.7.2). Read-only Space queries go back to the older `CGS…` functions and are used by many window managers, but nothing guarantees them.

The pause covers missing functions, no window-server connection, no Space data while displays are connected, renamed dictionary keys (`"Display Identifier"`, `"Spaces"`, `"ManagedSpaceID"`), and changed Space type codes (no Space reporting type 0, a normal desktop). It does not cover subtler changes, such as `SLSCopySpacesForWindows` returning wrong Spaces or the unexplained `7` argument changing meaning. Those show up as windows that are not managed, or managed on the wrong Space.

**After every macOS update**, check that:
1. Paperi is not paused with “macOS compatibility”.
2. `paperi msg status` lists each display with its Spaces, and windows tile on every display.
3. Moving a window to another Space in Mission Control moves its column to that Space's strip.
4. A three-finger swipe does not also scroll or navigate the page in a Chromium browser, and two-finger scrolling still works.

