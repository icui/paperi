# Snapshot focus-scroll experiment (uncommitted)

Enable `"experimentalSnapshotScroll": true` in config.json and reload Paperi.
Remove the setting or set it to false to restore the position-write animation.
A duration of zero bypasses both animation paths. Screen Recording permission
is required; capture failure falls back to the existing AX animation for that command.

The experiment uses ScreenCaptureKit's SCScreenshotManager (macOS 14+) to capture
one background excluding the strip windows and one image per strip window.
A click-through, opaque overlay masks the originals. Core Animation interpolates
snapshot-layer positions; the existing AX path places the real windows once
underneath. After the transition, geometry is checked up to three times, then
the overlay is removed regardless of confirmation. No capture is written to disk.
The captured background and window contents remain frozen during the transition.

Limits: at most 12 windows and 256 MiB estimated image storage (not total GPU
allocation). Captures are currently sequential. There is no warm capture cache,
live content streaming, cursor forwarding, or seamless snapshot retargeting.
A new command removes the previous overlay and captures again, so rapid reversals
may expose the real target positions. Mouse interaction removes the overlay;
the real windows may already be at their destination. This is a visual feasibility
experiment, not a replacement for the existing interruptible AX path.

`paperi msg status` → `performance.snapshot` reports state, captureMS, textureBytes,
and fallback reason. `completed` means a sampled match of the real final geometry;
`handoffUnconfirmed` means the overlay was removed after the bounded wait.
These fields do not measure displayed GPU frame pacing. AX tick counters describe
the other backend and must not be interpreted as snapshot-render measurements.

Evaluate capture delay separately from transition smoothness. Check text sharpness,
background masking, shadows/stacking, permission denial, display/Space changes,
mouse interruption, repeated/reversed commands, and final-frame handoff.

API references:
- https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
- https://developer.apple.com/documentation/screencapturekit/sccontentfilter
