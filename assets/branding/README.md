# Paperi identity

A symmetric three-card carousel honors Palm webOS multitasking while retaining Paperi's paper-and-windows identity. A warm ivory active card sits ahead of two stone-colored peers on flat graphite. One small terracotta gesture bar provides the only color accent; no lettering or interface details are needed.

The card-and-gesture reference comes from the [Palm Pre user guide](https://support.bell.ca/_web/guides/User-Guides/Mobile/PalmOne/Palm-EN/palm_pre_userguide_en%28en%29.pdf).

- `Paperi.svg`: editable vector artwork.
- `Paperi.png`: transparent 1024px app icon.
- `Paperi.icns` / `Paperi.iconset`: native macOS icon and all resolution variants.
- `MenuBar.png` / `MenuBar@2x.png`: transparent black template artwork at 20 × 18pt.

The runtime menubar icon is drawn by `Sources/Paperi/BrandIcon.swift` and marked as an AppKit template so macOS handles appearance and selection. Pause and permission indicators remain visible beside it.

Regenerate the raster assets with `./scripts/generate-branding.sh`. Package with `./scripts/build-app.sh`.
