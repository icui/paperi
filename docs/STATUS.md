# Implementation status

## Increment 1: repository, diagnostic shell, and initial core

Implemented:

- Swift package with a platform-independent core, isolated private-API bridge, read-only diagnostics, and a menu bar shell.
- Conservative system-overlay/transient classification and explicit pending metadata states.
- Logical tab-container slots, membership validation, row fallback navigation, column/row swaps, slurp/barf primitives, centering, weighted stacked frames, and edge-clamped virtual positions.
- Section packing and release-target selection as pure functions. No live gesture capture or animation.
- AX snapshots and a bounded-duration event recorder for baseline investigation.
- Regression tests, build tasks, local app bundling/signing script, and a manual feasibility protocol.

Incomplete release gates:

- Step 1: real baseline traces and installed-manager performance measurements.
- Step 2: affirmative native-tab grouping, live multi-display validation, popup reproducer and no-injection Space transfer. The bridge currently only queries Spaces/window IDs.
- Step 3: full event reducer, tab reconciliation, fixture parity against recorded interactions, and broader invariants.
- Steps 4–6: effect scheduler, hotkeys, live incremental registry, configuration, recovery, daily-use soak, notarization and distribution.
- Stretch: native touch capture, page frame placement, animation and live performance validation. Section anchors currently describe pages; the ordinary strip placement function does not yet consume section packing.

The current binary never writes window geometry, changes focus, moves Spaces or installs management shortcuts. Keep it diagnostic-only until the platform feasibility gates are verified.

## Increment 2: additional pure core commands

- Added canvas-relative width and stacked-height resizing. Width stays within the usable canvas; height redistribution keeps sibling rows positive and preserves their relative weights beyond a reserved minimum.
- Added the two-column split command: the left and focused columns occupy equal halves with one gap, including on displays with negative origins. No left column means no change.
- Added a Codable layout state separating tiled and user-floating logical slots. Floating toggles retain native-tab membership and preferred column width, remove empty columns, and reject excluded/pending classifications. Retiling inserts a column after the current tiled focus; this is a deterministic policy awaiting recorded parity fixtures.
- Added four regression tests covering resizing, split geometry, floating tab containers, exclusion, and invalid input.
- Validation in this implementation session: editor diagnostics report no errors. `./scripts/swift.sh test` could not start because `xcode-select` reports no active developer directory. These new tests have not been executed; the host results below apply to increment 1.

These are in-memory commands only; they do not enable window management or resolve the native feasibility gates.

## Validation on the initial host

- Swift 6.4 / Command Line Tools; macOS 26.7.2, arm64. The SDK is macOS 27; deployment target is macOS 14. Older OS support has not been exercised.
- 11 Swift Testing regressions pass. Editor diagnostics report no errors.
- Release app builds and is locally ad hoc signed. This is not a notarized release.
- Read-only native discovery reports AX permission available, Space topology available and window/Space membership resolved for accessible windows.
- One built-in display is connected; “Displays have separate Spaces” is disabled. The independent-display release gate cannot be validated in this setup. No settings were changed.
- Initial cold-ish debug discovery took approximately 2.6 seconds across running apps. It is not a keystroke-latency benchmark; windows on inactive Spaces can be absent from public AX discovery.
- A release cached-layout microbenchmark with 50 windows and 1,000 iterations measured p50 about 0.0048 ms and p95 about 0.0055 ms. This excludes AX traffic, animation, input and physical rendering; it establishes no end-to-end performance advantage.
- The Swift wrapper works around stale private PackageDescription interfaces in the installed CLT and explicitly loads its bundled Testing macro plugin. Toolchain framework search-path warnings remain, but builds complete. No system toolchain files were edited.
