# Snapshot swipe prototype

The snapshot experiment is now reserved for swipes. Keyboard focus commands
always use the existing position-write animation, including when
`experimentalSnapshotScroll` is true.

Enable `"experimentalSnapshotScroll": true` in config.json and reload Paperi.
Screen Recording permission is required. To exercise the renderer before touch
capture is connected:

```sh
paperi msg swipe right       # simulate a full swipe to the right neighbour
paperi msg swipe left 0.3    # simulate a short swipe, then snap back
paperi msg status
```

Directions name the destination neighbour, as with `focus`. The prototype uses
the focused window's display/Space; pointer-display ownership is still pending.
No global trackpad listener or system-gesture setting detection is installed yet.

ScreenCaptureKit captures a background excluding the strip and an image per
window. Images track progress without moving real windows. Snap-back returns
to the capture geometry. Commit changes focus once and places real windows under
the overlay while images settle. Bounded frame observations check stability;
images then receive a short correction towards observed positions when needed.
This is a candidate fix for the reported landing offset, not live validation of it.
An ordinary refresh still follows; verify that it causes no second jump.

`status.performance.swipe` reports capture time, texture bytes, state,
`landingCorrectionPT`, handoff time and total time. `completed` means stable
observations near the intended target, `landedAdjusted` means stable observations
off target, and `handoffUnsettled` means the bounded wait expired. None measures
displayed GPU cadence. Capture failure falls back to an ordinary focus command
on a committed release; there is no live AX finger-tracking fallback.

Mouse input, permission loss, display/Space changes, pause/stop and keyboard
commands dismiss the overlay. Resizing during tracking cancels it. Real windows
may already have moved if a committed settle is interrupted. A new swipe during
settling currently dismisses and recaptures; seamless interruption remains open.

Limits: 12 windows, 256 MiB estimated image storage (not total GPU allocation),
sequential captures, frozen content, no warm cache or streaming. Captures stay
in memory. Validate capture bounds, scale, text, stacking, shadows, negative-origin
displays, slow apps, popups and the final handoff live before enabling real input.
