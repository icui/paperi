#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/generate-branding.sh
./scripts/swift.sh build -c release
app="dist/Paperi.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp assets/branding/Paperi.icns "$app/Contents/Resources/Paperi.icns"
bin_dir="$(./scripts/swift.sh build -c release --show-bin-path)"
cp "$bin_dir/paperi" "$app/Contents/MacOS/Paperi"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.paperi.app</string>
<key>CFBundleName</key><string>Paperi</string>
<key>CFBundleExecutable</key><string>Paperi</string>
<key>CFBundleIconFile</key><string>Paperi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
if [ -n "${PAPERI_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$PAPERI_SIGN_IDENTITY" "$app"
else
    # Ad hoc signatures change their code hash on every build, and macOS ties
    # the Accessibility grant to the designated requirement. Pin it to the
    # bundle identifier so a grant survives rebuilds/reinstalls. (Weaker than
    # a real identity: any local binary claiming this identifier matches.)
    codesign --force --sign - -r='designated => identifier "dev.paperi.app"' "$app"
fi
printf 'Built %s (local development signature; not notarized)\n' "$app"
