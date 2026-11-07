#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/swift.sh build -c release
app="dist/Paperi.app"
mkdir -p "$app/Contents/MacOS"
bin_dir="$(./scripts/swift.sh build -c release --show-bin-path)"
cp "$bin_dir/paperi" "$app/Contents/MacOS/Paperi"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.paperi.app</string>
<key>CFBundleName</key><string>Paperi</string>
<key>CFBundleExecutable</key><string>Paperi</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${PAPERI_SIGN_IDENTITY:--}" "$app"
printf 'Built %s (local development signature; not notarized)\n' "$app"
