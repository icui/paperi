# Snapshot swipe implementation

The snapshot renderer powers trackpad slot swipes. Keyboard focus commands
always use the existing position-write animation.

No feature flag is required. Screen Recording permission is required. Both real
three-finger trackpad swipes and simulated swipes via IPC are supported:

```sh
paperi msg swipe right       # simulate a full swipe to the right neighbour
paperi msg swipe left 0.3    # simulate a short swipe, then snap back
paperi msg status            # reports gesture.enabled and performance.swipe
```

### Trackpad gesture interaction
- **Three-finger horizontal swipe**: Moves the strip of the display under the pointer. Windows follow fingers continuously during contact.
- **One slot per gesture**: Clamped to at most one slot either side with rubber-band resistance beyond limits and at strip ends.
- **Direction**: Natural scrolling by default (fingers left -> content moves left -> reveals right neighbour). Configurable with `"gesture.invert": true`.
- **Reversal**: Mid-gesture reversal crossing back through zero towards the opposite neighbour is supported.
- **Release**: Commits to target neighbour if progress >= `commitThreshold` (default 0.5) or if release velocity exceeds `flickVelocity` (default 1.5 slots/s); otherwise snaps back without moving real windows.
- **System conflict detection**: Paperi monitors macOS system trackpad settings (`com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad`). If three-finger Spaces, Mission Control or drag gestures are active, the Paperi gesture disables itself, reports conflicts in `status.gesture.blockedBy`, adds a warning in the menu bar and shows a popover directing to Trackpad Settings.

### Configuration (`config.json`)
```json
{
  "gesture": {
    "enabled": true,
    "fingers": 3,
    "travel": 0.25,
    "commitThreshold": 0.5,
    "flickVelocity": 1.5,
    "invert": false
  }
}
```

ScreenCaptureKit captures a background excluding the strip and an image per
window. Images track progress without moving real windows. Snap-back returns
to the capture geometry. Commit changes focus once and places real windows under
the overlay while images settle. Bounded frame observations check stability;
images then receive a short correction towards observed positions when needed.
An ordinary refresh follows to reconcile final geometry.

`status.performance.swipe` reports capture time, texture bytes, state,
`landingCorrectionPT`, handoff time and total time. `status.gesture` reports
`enabled` and `blockedBy`.
