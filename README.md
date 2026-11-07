# Paperi

Standalone macOS scrolling window manager in development. See [PLAN.md](PLAN.md) for the intended behavior and release gates.

The current implementation provides a pure Swift layout core (including resize, split, and floating transitions), regression tests, read-only native diagnostics, and an inactive menu bar shell. **It does not yet manage windows.** Native tabs, Space transfers, full keyboard parity, and trackpad capture remain feasibility work.

## Development

Requires macOS 14+ and Swift 6+ (Xcode or Command Line Tools). The initial host is macOS 26.7.2 on arm64; older releases are not validated. There are no third-party package dependencies. The Swift wrapper isolates a stale-private-manifest-interface issue found in this host's Command Line Tools and loads its bundled Swift Testing plugin explicitly; it never changes the installed toolchain.

```sh
./scripts/swift.sh build
./scripts/swift.sh test
./scripts/swift.sh run -c release paperi benchmark-core
./scripts/swift.sh run paperi snapshot
./scripts/swift.sh run paperi record 30 > captures/session.jsonl
```

Create `captures/` before redirecting; captures are ignored by Git. Snapshot and event recording never reposition or focus windows or register management shortcuts, so they can be used alongside Hammerspoon. Titles are omitted unless `snapshot --include-titles` is explicitly requested. IDs, bundle identifiers and geometry can still reveal activity; review captures before sharing.

Accessibility access is needed to enumerate and observe application windows. Without it, snapshots still report available display/Space information. No automatic permission prompt is shown by CLI diagnostics. Build the app and launch its menu to request access:

```sh
./scripts/build-app.sh
open dist/Paperi.app
```

The menu bar app is diagnostic-only. Developer signing is ad hoc by default; set `PAPERI_SIGN_IDENTITY` to a signing identity for a stable signed build. Ad hoc rebuilding may require renewing Accessibility access. No notarization or distribution setup is included yet.

Snapshots include raw AppKit display coordinates and AX window coordinates with explicit field names; they are not interchangeable. Optional private SkyLight/AX functions are dynamically resolved, and unavailable values are reported rather than guessed. A successful Space query is not proof that Space transfer is supported.

Event recording observes apps/windows present at recording start. It is a baseline instrument, not the final incremental registry: new process launches and all newly created window notifications are not yet fully subscribed. `AXTabs` is captured when exposed, but absence does not establish that a window has no native tabs. No tab-group discovery is claimed.

See [implementation status](docs/STATUS.md) and [manual feasibility protocol](docs/FEASIBILITY.md).
